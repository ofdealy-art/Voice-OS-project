import Carbon.HIToolbox
import XCTest
@testable import ScreenMateCore
@testable import ScreenMateKit

@MainActor
final class AssistantViewModelTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    private func makeModel(
        settings: AppSettings = AssistantViewModelTests.demoSettings(),
        capturer: FakeScreenCapturer = FakeScreenCapturer()
    ) -> (AssistantViewModel, FakeScreenCapturer, FakeSpeechTranscriber) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenmate-vm-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)

        let (environment, transcriber, probe) = makeTestEnvironment(
            settings: settings,
            probe: FakePermissionProbe(states: [
                .microphone: .granted,
                .speechRecognition: .granted,
                .screenRecording: .granted,
            ]),
            directory: directory
        )
        _ = probe

        let voice = VoiceController(
            transcriber: transcriber,
            permissions: environment.permissions,
            settingsProvider: { environment.settings }
        )
        let screen = ScreenAwarenessController(
            capturer: capturer,
            permissions: environment.permissions,
            settingsProvider: { environment.settings }
        )
        let model = AssistantViewModel(environment: environment, voice: voice, screen: screen)
        return (model, capturer, transcriber)
    }

    /// The offline demo provider, so a turn completes with no network.
    static func demoSettings() -> AppSettings {
        var settings = AppSettings()
        settings.chatProviderID = DemoChatProvider.providerID
        settings.chatModelID = "demo-1"
        settings.hasCompletedOnboarding = true
        settings.speakResponses = false
        return settings
    }

    private func waitUntilIdle(_ model: AssistantViewModel, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isBusy {
            if Date() > deadline { XCTFail("the turn did not finish in time"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<4 { await Task.yield() }
    }

    // MARK: - Chat state

    func testSendingAppendsUserAndAssistantMessages() async throws {
        let (model, _, _) = makeModel()
        model.composerText = "hello there"
        model.sendComposer()

        XCTAssertEqual(model.conversation.messages.first?.role, .user)
        XCTAssertEqual(model.conversation.messages.first?.text, "hello there")
        XCTAssertEqual(model.composerText, "", "the composer clears on send")

        try await waitUntilIdle(model)

        XCTAssertEqual(model.conversation.messages.count, 2)
        let reply = model.conversation.messages[1]
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertFalse(reply.isStreaming)
        XCTAssertFalse(reply.text.isEmpty)
        XCTAssertEqual(model.activity, .idle)
    }

    func testEmptyInputIsRejectedWithAnExplanation() {
        let (model, _, _) = makeModel()
        model.composerText = "   "
        model.sendComposer()

        XCTAssertTrue(model.conversation.messages.isEmpty)
        XCTAssertEqual(model.banner?.message, AppError.emptyInput.errorDescription)
        XCTAssertEqual(model.banner?.nextStep, AppError.emptyInput.recoverySuggestion)
    }

    func testMissingAPIKeyFailsBeforeAnyRequestAndPointsAtSettings() async throws {
        var settings = Self.demoSettings()
        settings.chatProviderID = AnthropicChatProvider.providerID
        settings.chatModelID = "claude-sonnet-5"
        let (model, _, _) = makeModel(settings: settings)

        model.composerText = "hello"
        model.sendComposer()

        XCTAssertEqual(model.banner?.kind, .error)
        XCTAssertEqual(model.banner?.settingsAnchor, .provider)
        XCTAssertEqual(
            model.banner?.message,
            AppError.missingAPIKey(provider: "Anthropic").errorDescription
        )
        // The user's message is still shown, so nothing they typed is lost.
        XCTAssertEqual(model.conversation.messages.count, 1)
    }

    func testASecondSendIsRefusedWhileATurnIsRunning() async throws {
        let (model, _, _) = makeModel()
        model.composerText = "first"
        model.sendComposer()

        model.composerText = "second"
        model.sendComposer()

        XCTAssertEqual(model.banner?.kind, .info)
        XCTAssertEqual(model.conversation.messages.filter { $0.role == .user }.count, 1)
        try await waitUntilIdle(model)
    }

    func testStopGenerationEndsTheTurnAndRemovesAnEmptyBubble() async throws {
        let (model, _, _) = makeModel()
        model.composerText = "tell me a long story"
        model.sendComposer()
        model.stopGeneration()

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.activity, .idle)
        XCTAssertFalse(model.conversation.messages.contains { $0.isStreaming })
        try await waitUntilIdle(model)
    }

    func testClearConversationStartsAFreshTranscript() async throws {
        let (model, _, _) = makeModel()
        model.composerText = "hello"
        model.sendComposer()
        try await waitUntilIdle(model)
        let firstID = model.conversation.id

        model.clearConversation()

        XCTAssertTrue(model.conversation.messages.isEmpty)
        XCTAssertNotEqual(model.conversation.id, firstID)
        XCTAssertNil(try model.environment.conversationStore.load(id: firstID))
    }

    func testConversationIsPersistedAndTitled() async throws {
        let (model, _, _) = makeModel()
        model.composerText = "explain this stack trace"
        model.sendComposer()
        try await waitUntilIdle(model)

        let stored = try model.environment.conversationStore.load(id: model.conversation.id)
        XCTAssertEqual(stored?.messages.count, 2)
        XCTAssertEqual(stored?.title, "explain this stack trace")
        XCTAssertEqual(stored?.providerID, DemoChatProvider.providerID)
    }

    func testNothingIsPersistedWhenSavingIsOff() async throws {
        var settings = Self.demoSettings()
        settings.saveConversations = false
        let (model, _, _) = makeModel(settings: settings)

        model.composerText = "private question"
        model.sendComposer()
        try await waitUntilIdle(model)

        XCTAssertTrue(try model.environment.conversationStore.summaries().isEmpty)
    }

    // MARK: - Voice

    func testVoiceTranscriptIsSentAsAVoiceMessage() async throws {
        let (model, _, transcriber) = makeModel()
        model.voice.start()
        for _ in 0..<6 { await Task.yield() }
        model.voice.stop()
        for _ in 0..<6 { await Task.yield() }
        transcriber.emit(.final("what am I looking at"))
        for _ in 0..<6 { await Task.yield() }

        XCTAssertEqual(model.conversation.messages.first?.text, "what am I looking at")
        XCTAssertEqual(model.conversation.messages.first?.source, .voice)
        try await waitUntilIdle(model)
    }

    func testListeningIsReflectedInTheActivityIndicator() async {
        let (model, _, transcriber) = makeModel()
        model.voice.start()
        for _ in 0..<6 { await Task.yield() }
        transcriber.emit(.level(0.5))
        for _ in 0..<6 { await Task.yield() }

        XCTAssertTrue(model.activity.isCapturingAudio)
        XCTAssertEqual(model.activityStyle, .listening)
    }

    // MARK: - Screen capture

    func testApprovedCaptureIsAttachedAndThenReleased() async throws {
        var settings = Self.demoSettings()
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = true
        settings.alwaysPreviewBeforeSending = true
        let (model, capturer, _) = makeModel(settings: settings)

        model.captureScreen(scope: .activeWindow)
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(capturer.captureCalls.count, 1)
        XCTAssertNotNil(model.screen.previewContext)
        XCTAssertNil(model.attachmentSummary, "nothing is attached before approval")

        model.screen.approvePreview()
        XCTAssertNotNil(model.attachmentSummary)

        model.composerText = "what is this?"
        model.sendComposer()
        XCTAssertEqual(model.conversation.messages.first?.attachments.count, 1)

        try await waitUntilIdle(model)
        XCTAssertNil(model.screen.attachedContext, "the capture is released after the turn")
    }

    func testCaptureIsRefusedWhileScreenAwarenessIsOff() async {
        let (model, capturer, _) = makeModel()
        model.captureScreen(scope: .activeWindow)
        for _ in 0..<8 { await Task.yield() }

        XCTAssertTrue(capturer.captureCalls.isEmpty)
        XCTAssertEqual(model.banner?.settingsAnchor, .privacy)
    }

    func testSendingACaptureWithSharingOffFailsInsteadOfSendingNothing() async throws {
        var settings = Self.demoSettings()
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = true
        settings.alwaysPreviewBeforeSending = false
        let (model, _, _) = makeModel(settings: settings)

        model.captureScreen(scope: .activeWindow)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(model.screen.attachedContext)

        // The user turns sharing off between capturing and sending.
        model.environment.settings.sendScreenContentToProvider = false

        model.composerText = "what is this?"
        model.sendComposer()
        try await waitUntilIdle(model)

        XCTAssertEqual(
            model.banner?.message,
            AppError.screenSharingWithProviderDisabled.errorDescription
        )
    }

    func testDisclosureNamesExactlyWhatWasSent() async throws {
        var settings = Self.demoSettings()
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = true
        settings.alwaysPreviewBeforeSending = false
        let (model, _, _) = makeModel(settings: settings)

        model.captureScreen(scope: .activeWindow)
        for _ in 0..<8 { await Task.yield() }
        model.composerText = "what is this?"
        model.sendComposer()
        try await waitUntilIdle(model)

        XCTAssertEqual(
            model.lastScreenDisclosure,
            "A picture of your screen was sent to your AI provider."
        )
    }

    func testTurningScreenAwarenessOffThroughSettingsDropsTheAttachment() async {
        var settings = Self.demoSettings()
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = true
        settings.alwaysPreviewBeforeSending = false
        let (model, _, _) = makeModel(settings: settings)

        model.captureScreen(scope: .activeWindow)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(model.screen.attachedContext)

        model.environment.settings.screenAwarenessEnabled = false
        for _ in 0..<4 { await Task.yield() }

        XCTAssertNil(model.screen.attachedContext)
    }

    // MARK: - Disclosure strings

    func testDisclosureCoversEachCombination() {
        XCTAssertEqual(
            AssistantViewModel.disclosure(image: true, text: true),
            "A picture of your screen and the text read from it were sent to your AI provider."
        )
        XCTAssertEqual(
            AssistantViewModel.disclosure(image: false, text: true),
            "Text read from your screen was sent to your AI provider. No picture was sent."
        )
        XCTAssertNil(AssistantViewModel.disclosure(image: false, text: false))
    }

    func testErrorsRouteToTheRightSettingsTab() {
        XCTAssertEqual(AssistantViewModel.anchor(for: .missingAPIKey(provider: "x")), .provider)
        XCTAssertEqual(AssistantViewModel.anchor(for: .microphonePermissionDenied), .voice)
        XCTAssertEqual(AssistantViewModel.anchor(for: .screenRecordingPermissionDenied), .privacy)
        XCTAssertEqual(AssistantViewModel.anchor(for: .webAccessDisabled), .web)
        XCTAssertNil(AssistantViewModel.anchor(for: .networkUnavailable))
    }
}

@MainActor
final class ToolConfirmationCenterTests: XCTestCase {
    private func request(_ name: String = "copy_to_clipboard") -> ToolConfirmationRequest {
        ToolConfirmationRequest(toolName: name, prompt: "Copy this?", actionVerb: "replace your clipboard")
    }

    func testApprovalResumesWithTrue() async {
        let center = ToolConfirmationCenter()
        let confirmer = InteractiveToolConfirmer(center: center)

        let task = Task { await confirmer.confirm(request()) }
        while center.pending == nil { await Task.yield() }
        center.approve()

        let approved = await task.value
        XCTAssertTrue(approved)
        XCTAssertNil(center.pending)
    }

    func testDeclineResumesWithFalse() async {
        let center = ToolConfirmationCenter()
        let confirmer = InteractiveToolConfirmer(center: center)

        let task = Task { await confirmer.confirm(request()) }
        while center.pending == nil { await Task.yield() }
        center.decline()

        XCTAssertFalse(await task.value)
    }

    func testCancellingAPendingRequestDeclinesIt() async {
        let center = ToolConfirmationCenter()
        let confirmer = InteractiveToolConfirmer(center: center)

        let task = Task { await confirmer.confirm(request()) }
        while center.pending == nil { await Task.yield() }
        center.cancelPending()

        XCTAssertFalse(await task.value, "a dropped confirmation must default to declining")
    }

    func testASecondRequestDeclinesTheFirstRatherThanLosingIt() async {
        let center = ToolConfirmationCenter()
        let confirmer = InteractiveToolConfirmer(center: center)

        let first = Task { await confirmer.confirm(request("open_url")) }
        while center.pending == nil { await Task.yield() }

        let second = Task { await confirmer.confirm(request("create_note")) }
        while center.pending?.toolName != "create_note" { await Task.yield() }
        center.approve()

        XCTAssertFalse(await first.value)
        XCTAssertTrue(await second.value)
    }
}

final class SpokenTextTests: XCTestCase {
    func testMarkdownIsStrippedBeforeSpeaking() {
        let input = """
        ## Summary
        - **Important** point
        - A [link](https://example.com)
        """
        let spoken = AVSpeechSpeaker.spokenText(from: input)
        XCTAssertFalse(spoken.contains("#"))
        XCTAssertFalse(spoken.contains("**"))
        XCTAssertFalse(spoken.contains("https://example.com"))
        XCTAssertTrue(spoken.contains("Important point"))
        XCTAssertTrue(spoken.contains("link"))
    }

    func testCodeBlocksAreAnnouncedRatherThanRead() {
        let input = "Try this:\n```swift\nlet x = 1\n```\nThen build."
        let spoken = AVSpeechSpeaker.spokenText(from: input)
        XCTAssertFalse(spoken.contains("let x = 1"))
        XCTAssertTrue(spoken.contains("code block omitted"))
        XCTAssertTrue(spoken.contains("Then build."))
    }

    func testInlineCodeKeepsItsContent() {
        XCTAssertEqual(AVSpeechSpeaker.spokenText(from: "Run `swift build` now."), "Run swift build now.")
    }

    func testPlainTextIsUnchanged() {
        let input = "That is a type mismatch on line 12."
        XCTAssertEqual(AVSpeechSpeaker.spokenText(from: input), input)
    }
}

final class HotKeyTranslationTests: XCTestCase {
    func testModifierFlagsTranslateToCarbon() {
        let shortcut = KeyboardShortcut.defaultToggle
        let carbon = HotKeyManager.carbonModifiers(from: shortcut.modifierFlags)
        XCTAssertNotEqual(carbon, 0)
        // ⌥⌘ must include both bits and neither control nor shift.
        XCTAssertEqual(carbon & UInt32(cmdKey), UInt32(cmdKey))
        XCTAssertEqual(carbon & UInt32(optionKey), UInt32(optionKey))
        XCTAssertEqual(carbon & UInt32(controlKey), 0)
        XCTAssertEqual(carbon & UInt32(shiftKey), 0)
    }

    func testSignatureIsAFourCharacterCode() {
        XCTAssertEqual(HotKeyManager.signature, 0x53_43_4D_54) // "SCMT"
    }

    func testDefaultShortcutsAreDistinct() {
        let shortcuts = [
            KeyboardShortcut.defaultToggle,
            .defaultVoice,
            .defaultCapture,
        ]
        let keys = shortcuts.map { "\($0.keyCode)-\($0.modifierFlags)" }
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}
