import AppKit
import Combine
import Foundation
import ScreenMateCore

/// The assistant's presentation state, and the one place a turn is started.
///
/// It owns the conversation, the current activity, the composer, and the wiring
/// between voice, capture and the chat engine. Everything it does is driven by
/// injected services, so a test can construct one with a scripted provider and a
/// fake transcriber and exercise a whole turn.
@MainActor
public final class AssistantViewModel: ObservableObject {
    // MARK: Published state

    @Published public private(set) var conversation: Conversation
    @Published public private(set) var activity: AssistantActivity = .idle
    @Published public var composerText: String = ""
    @Published public private(set) var banner: BannerMessage?
    @Published public var isPanelExpanded = false
    @Published public var isShowingSettings = false
    @Published public var isShowingOnboarding = false
    /// Set after a send, so the user can see what actually left their Mac.
    @Published public private(set) var lastScreenDisclosure: String?

    public struct BannerMessage: Identifiable, Equatable {
        public enum Kind: Equatable {
            case error
            case info
            case success
        }

        public let id = UUID()
        public let kind: Kind
        public let message: String
        public let nextStep: String?
        /// Non-nil when the banner offers a jump into Settings.
        public let settingsAnchor: SettingsTab?

        public init(kind: Kind, message: String, nextStep: String?, settingsAnchor: SettingsTab? = nil) {
            self.kind = kind
            self.message = message
            self.nextStep = nextStep
            self.settingsAnchor = settingsAnchor
        }
    }

    // MARK: Dependencies

    public let environment: AppEnvironment
    public let voice: VoiceController
    public let screen: ScreenAwarenessController

    private var turnTask: Task<Void, Never>?
    private var lastSpokenMessageID: UUID?
    /// Where `capture_screen` deposits a mid-turn capture for the UI to pick up.
    private let toolCaptureBox = ScreenContextBox()

    public init(
        environment: AppEnvironment,
        voice: VoiceController? = nil,
        screen: ScreenAwarenessController? = nil,
        conversation: Conversation = Conversation()
    ) {
        self.environment = environment
        self.conversation = conversation
        self.voice = voice ?? VoiceController(
            transcriber: environment.transcriber,
            permissions: environment.permissions,
            settingsProvider: { environment.settings }
        )
        self.screen = screen ?? ScreenAwarenessController(
            capturer: environment.screenCapturer,
            permissions: environment.permissions,
            settingsProvider: { environment.settings }
        )
        self.isShowingOnboarding = !environment.settings.hasCompletedOnboarding
        wireUp()
    }

    private func wireUp() {
        voice.onTranscript = { [weak self] transcript in
            self?.send(text: transcript, source: .voice)
        }
        voice.onAnnouncement = { [weak self] message in
            self?.announce(message)
        }
        voice.onWillStartListening = { [weak self] in
            // Speaking over the assistant interrupts it.
            guard let self, self.environment.settings.interruptSpeechWhenUserSpeaks else { return }
            self.environment.speaker.stop()
        }

        voice.onStateChange = { [weak self] state in
            self?.reflect(voiceState: state)
        }

        screen.onStateChange = { [weak self] state in
            self?.reflect(screenState: state)
        }
        screen.onAnnouncement = { [weak self] message in
            self?.announce(message)
        }
        screen.onNeedsScreenAwareness = { [weak self] in
            self?.banner = BannerMessage(
                kind: .info,
                message: AppError.screenAwarenessDisabled.errorDescription ?? "",
                nextStep: AppError.screenAwarenessDisabled.recoverySuggestion,
                settingsAnchor: .privacy
            )
        }
        screen.onError = { [weak self] error in
            self?.present(error)
        }

        environment.onScreenAwarenessDisabled = { [weak self] in
            self?.screen.screenAwarenessDisabled()
        }
        environment.onPermissionRevoked = { [weak self] capability in
            self?.handleRevocation(of: capability)
        }
        environment.speaker.onFinish = { [weak self] in
            guard let self, case .speaking = self.activity else { return }
            self.activity = .idle
        }
    }

    /// Mirrors voice state into `activity` so the widget and the status line show
    /// one consistent thing. A running turn wins: a transcript being submitted
    /// must not overwrite "thinking".
    private func reflect(voiceState: VoiceState) {
        switch voiceState {
        case .listening(let level, _):
            activity = .listening(level: level)
        case .finalizing:
            activity = .transcribing
        case .permissionDenied(let error), .failed(let error):
            activity = .failed(MessageFailure(error))
            present(error, anchor: .voice)
        case .requestingPermission:
            activity = .transcribing
        case .idle:
            if !isBusy, activity.isCapturingAudio { activity = .idle }
        }
    }

    private func reflect(screenState: ScreenCaptureState) {
        if screenState.isCapturing {
            activity = .readingScreen
            return
        }
        if case .blocked(let reason) = screenState {
            banner = BannerMessage(kind: .info, message: reason, nextStep: nil, settingsAnchor: .privacy)
        }
        if !isBusy, activity.isReadingScreen { activity = .idle }
    }

    // MARK: - Sending

    public func sendComposer() {
        let text = composerText
        composerText = ""
        send(text: text, source: .typed)
    }

    public func send(text: String, source: ChatMessage.Source) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedContext = screen.attachedContext

        guard !trimmed.isEmpty || attachedContext != nil else {
            present(AppError.emptyInput)
            return
        }
        guard turnTask == nil else {
            // A turn is already running; queueing would reorder the transcript.
            banner = BannerMessage(
                kind: .info,
                message: "ScreenMate is still working on the last message.",
                nextStep: "Press Stop if you want to interrupt it."
            )
            return
        }

        banner = nil
        lastScreenDisclosure = nil

        let provider: any ChatModelProviding
        do {
            provider = try environment.makeChatProvider()
        } catch {
            appendUserMessage(trimmed, source: source, context: attachedContext)
            present(AppError.wrapping(error), anchor: .provider)
            return
        }

        appendUserMessage(trimmed, source: source, context: attachedContext)
        startTurn(provider: provider, screenContext: attachedContext)
    }

    private func appendUserMessage(
        _ text: String,
        source: ChatMessage.Source,
        context: ScreenContext?
    ) {
        let attachments = context.map {
            [$0.attachment(includeExtractedText: environment.settings.saveConversations
                && environment.settings.runOCROnCaptures)]
        } ?? []
        conversation.messages.append(ChatMessage(
            role: .user,
            text: text,
            source: source,
            attachments: attachments
        ))
        conversation.updatedAt = Date()
    }

    private func startTurn(provider: any ChatModelProviding, screenContext: ScreenContext?) {
        let captureTool = CaptureScreenTool(
            capturer: environment.screenCapturer,
            deposit: toolCaptureBox
        )
        let engine = ChatEngine(
            provider: provider,
            runner: environment.makeToolRunner(extraTools: [captureTool])
        )
        let request = ChatEngine.Request(
            conversation: conversation,
            screenContext: screenContext,
            settings: environment.settings,
            toolContext: environment.makeToolContext()
        )

        // The placeholder is what streams into; it is created up front so the
        // transcript never jumps when the first token lands.
        let assistantMessage = ChatMessage(role: .assistant, text: "", source: .model, isStreaming: true)
        conversation.messages.append(assistantMessage)
        conversation.providerID = environment.settings.chatProviderID
        conversation.modelID = environment.settings.chatModelID
        activity = .thinking

        turnTask = Task { @MainActor [weak self] in
            for await update in engine.run(request) {
                guard let self else { return }
                self.handle(update, for: assistantMessage.id)
            }
            self?.finishTurn(messageID: assistantMessage.id)
        }
    }

    private func handle(_ update: ChatEngine.Update, for messageID: UUID) {
        switch update {
        case .activity(let activity):
            self.activity = activity

        case .textDelta(let delta):
            mutate(messageID) { $0.text += delta }

        case .toolInvocation(let record):
            if record.toolName == "capture_screen",
               record.outcome == .succeeded,
               let captured = toolCaptureBox.value {
                toolCaptureBox.discard()
                screen.adopt(captured)
            }
            mutate(messageID) { message in
                if let index = message.toolInvocations.firstIndex(where: { $0.id == record.id }) {
                    message.toolInvocations[index] = record
                } else {
                    message.toolInvocations.append(record)
                }
            }

        case .citations(let citations):
            mutate(messageID) { message in
                let known = Set(message.citations.map(\.url))
                message.citations.append(contentsOf: citations.filter { !known.contains($0.url) })
            }

        case .screenContextSent(let image, let text):
            lastScreenDisclosure = Self.disclosure(image: image, text: text)

        case .usage:
            break

        case .finished:
            mutate(messageID) { $0.isStreaming = false }

        case .failed(let error):
            mutate(messageID) { message in
                message.isStreaming = false
                if message.text.isEmpty {
                    message.failure = MessageFailure(error)
                }
            }
            if !error.isUserInitiated {
                present(error, anchor: Self.anchor(for: error))
            }
            activity = .failed(MessageFailure(error))
        }
    }

    private func finishTurn(messageID: UUID) {
        turnTask = nil
        screen.releaseAttachment()
        environment.toolConfirmations.cancelPending()

        mutate(messageID) { $0.isStreaming = false }
        // A turn that produced nothing at all should not leave a blank bubble.
        conversation.messages.removeAll { $0.role == .assistant && $0.isEmptyPlaceholder }
        conversation.refreshTitleFromContent()
        conversation.updatedAt = Date()
        persist()

        if case .failed = activity {
            // Keep the failure visible; the banner explains it.
        } else {
            activity = .idle
        }

        speakLastReplyIfEnabled(messageID: messageID)
    }

    private func mutate(_ messageID: UUID, _ body: (inout ChatMessage) -> Void) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
        body(&conversation.messages[index])
    }

    // MARK: - Interruption

    public func stopGeneration() {
        environment.speaker.stop()
        if voice.isListening {
            voice.cancel()
        }
        guard turnTask != nil else {
            activity = .idle
            return
        }
        turnTask?.cancel()
        turnTask = nil
        environment.toolConfirmations.cancelPending()
        screen.releaseAttachment()

        if let index = conversation.messages.lastIndex(where: { $0.role == .assistant }) {
            conversation.messages[index].isStreaming = false
            if conversation.messages[index].isEmptyPlaceholder {
                conversation.messages.remove(at: index)
            }
        }
        activity = .idle
        persist()
    }

    // MARK: - Speech out

    private func speakLastReplyIfEnabled(messageID: UUID) {
        guard environment.settings.speakResponses else { return }
        guard let message = conversation.messages.first(where: { $0.id == messageID }),
              message.failure == nil,
              !message.text.isEmpty,
              lastSpokenMessageID != messageID else { return }

        lastSpokenMessageID = messageID
        do {
            try environment.speaker.speak(
                message.text,
                voiceIdentifier: environment.settings.textToSpeechVoiceIdentifier,
                rate: environment.settings.speechRate
            )
            activity = .speaking
        } catch {
            // The text is already on screen, so this is a soft failure.
            present(AppError.wrapping(error), anchor: .voice)
        }
    }

    public func stopSpeaking() {
        environment.speaker.stop()
        if case .speaking = activity { activity = .idle }
    }

    public func speakAgain(_ message: ChatMessage) {
        guard !message.text.isEmpty else { return }
        do {
            try environment.speaker.speak(
                message.text,
                voiceIdentifier: environment.settings.textToSpeechVoiceIdentifier,
                rate: environment.settings.speechRate
            )
            activity = .speaking
        } catch {
            present(AppError.wrapping(error), anchor: .voice)
        }
    }

    // MARK: - Conversation management

    public func startNewConversation() {
        stopGeneration()
        persist()
        conversation = Conversation()
        lastScreenDisclosure = nil
        lastSpokenMessageID = nil
        banner = nil
    }

    public func clearConversation() {
        stopGeneration()
        let id = conversation.id
        conversation = Conversation()
        lastScreenDisclosure = nil
        lastSpokenMessageID = nil
        try? environment.conversationStore.delete(id: id)
        banner = BannerMessage(kind: .success, message: "Conversation cleared.", nextStep: nil)
    }

    public func load(conversationID: UUID) {
        guard let loaded = try? environment.conversationStore.load(id: conversationID) else { return }
        stopGeneration()
        conversation = loaded
    }

    /// Writes the current transcript, honouring "Save conversations".
    private func persist() {
        guard environment.settings.saveConversations else { return }
        guard !conversation.messages.isEmpty else { return }
        do {
            try environment.conversationStore.save(conversation)
        } catch {
            present(AppError.wrapping(error), anchor: .privacy)
        }
    }

    public func exportConversation(as format: ConversationExporter.Format) {
        guard !conversation.messages.isEmpty else {
            banner = BannerMessage(kind: .info, message: "There is nothing to export yet.", nextStep: nil)
            return
        }
        do {
            let data = try environment.exporter.export(conversation, as: format)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = environment.exporter.suggestedFilename(
                for: conversation,
                format: format
            )
            panel.canCreateDirectories = true
            // The panel has to be able to come forward over the floating panel.
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: [.atomic])
            banner = BannerMessage(kind: .success, message: "Exported to \(url.lastPathComponent).", nextStep: nil)
        } catch {
            present(AppError.wrapping(error))
        }
    }

    // MARK: - Capture

    public func captureScreen(scope: ScreenCaptureScope? = nil) {
        screen.capture(scope: scope)
    }

    public func toggleScreenAwareness() {
        environment.settings.screenAwarenessEnabled.toggle()
        if environment.settings.screenAwarenessEnabled && !environment.settings.sendScreenContentToProvider {
            banner = BannerMessage(
                kind: .info,
                message: "Screen awareness is on, but screen content is not being sent to your AI provider.",
                nextStep: "Turn on \"Send screen content to the AI provider\" in Settings › Privacy to let ScreenMate answer questions about your screen.",
                settingsAnchor: .privacy
            )
        }
    }

    // MARK: - Onboarding

    public func completeOnboarding() {
        environment.settings.hasCompletedOnboarding = true
        isShowingOnboarding = false
    }

    // MARK: - Banners and announcements

    public func dismissBanner() {
        banner = nil
        if case .failed = activity { activity = .idle }
    }

    /// Shows a neutral notice. Used for conditions that are not errors in the
    /// `AppError` sense, such as a keyboard shortcut another app already owns.
    public func presentInfo(message: String, nextStep: String?, anchor: SettingsTab? = nil) {
        banner = BannerMessage(kind: .info, message: message, nextStep: nextStep, settingsAnchor: anchor)
    }

    public func present(_ error: AppError, anchor: SettingsTab? = nil) {
        guard !error.isUserInitiated else { return }
        banner = BannerMessage(
            kind: .error,
            message: error.errorDescription ?? "Something went wrong.",
            nextStep: error.recoverySuggestion,
            settingsAnchor: anchor ?? Self.anchor(for: error)
        )
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func handleRevocation(of capability: PermissionCapability) {
        switch capability {
        case .microphone, .speechRecognition:
            voice.permissionRevoked()
        case .screenRecording:
            screen.permissionRevoked()
        case .accessibility:
            return // optional; nothing breaks
        }
        present(.permissionRevokedWhileRunning(capability: capability.displayName), anchor: .privacy)
    }

    // MARK: - Derived state for views

    public var canSend: Bool {
        turnTask == nil
            && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || screen.attachedContext != nil)
    }

    public var isBusy: Bool { turnTask != nil }

    /// Exposed as a publisher because `@Published private(set)` keeps `$activity`
    /// private to this type.
    public var activityPublisher: AnyPublisher<AssistantActivity, Never> {
        $activity.eraseToAnyPublisher()
    }

    public var activityStyle: AssistantActivityStyle {
        switch activity {
        case .idle: return .idle
        case .listening, .transcribing: return .listening
        case .readingScreen: return .screen
        case .searchingWeb: return .web
        case .thinking, .streaming, .runningTool: return .working
        case .awaitingToolConfirmation: return .awaitingApproval
        case .speaking: return .speaking
        case .failed: return .error
        }
    }

    /// The line shown under the composer when a capture is attached.
    public var attachmentSummary: String? {
        guard let context = screen.attachedContext else { return nil }
        var parts = ["\(context.label) · \(context.pixelWidth)×\(context.pixelHeight)"]
        if !context.redactionFindings.isEmpty {
            parts.append(RedactionFinding.summary(context.redactionFindings))
        }
        if !environment.settings.mayShareScreenWithProvider {
            parts.append("Will not be sent — screen sharing is off in Settings › Privacy.")
        }
        return parts.joined(separator: " · ")
    }

    static func disclosure(image: Bool, text: Bool) -> String? {
        if image && text { return "A picture of your screen and the text read from it were sent to your AI provider." }
        if image { return "A picture of your screen was sent to your AI provider." }
        if text { return "Text read from your screen was sent to your AI provider. No picture was sent." }
        return nil
    }

    static func anchor(for error: AppError) -> SettingsTab? {
        switch error {
        case .missingAPIKey, .invalidAPIKey, .modelUnavailable:
            return .provider
        case .microphonePermissionDenied, .speechRecognitionPermissionDenied,
             .speechRecognitionUnavailable, .noAudioInputDevice, .textToSpeechFailed:
            return .voice
        case .screenRecordingPermissionDenied, .accessibilityPermissionDenied,
             .screenAwarenessDisabled, .screenSharingWithProviderDisabled,
             .permissionRevokedWhileRunning:
            return .privacy
        case .webAccessDisabled, .webSearchNotConfigured:
            return .web
        default:
            return nil
        }
    }
}
