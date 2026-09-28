import AppKit
import Combine
import Foundation
import ScreenMateCore

/// The app's dependency graph, assembled once at launch.
///
/// Everything below the UI is injected from here, which is what lets the view
/// models be constructed with fakes in tests. It also owns the single source of
/// truth for settings and persists them on every change.
@MainActor
public final class AppEnvironment: ObservableObject {
    @Published public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persistSettings()
            reactToSettingsChange(from: oldValue)
        }
    }

    /// Non-fatal problems raised while wiring up, shown once in the panel.
    @Published public private(set) var startupWarning: String?

    public let paths: AppPaths
    public let settingsStore: any SettingsStoring
    public let secrets: any SecretStoring
    public let transport: any HTTPTransport
    public let providerCatalog: ProviderCatalog
    public let searchCatalog: SearchCatalog
    public let permissions: PermissionCenter
    public let toolConfirmations = ToolConfirmationCenter()
    public let exporter = ConversationExporter()

    public private(set) var conversationStore: any ConversationStoring

    public let speaker: AVSpeechSpeaker
    public let transcriber: any SpeechTranscribing
    public let screenCapturer: any ScreenCapturing
    public let audioDevices = AudioDeviceCatalog()
    public let hotKeys = HotKeyManager()

    /// Called when the user turns screen awareness off, so a held capture is
    /// released immediately rather than at the next turn.
    var onScreenAwarenessDisabled: (() -> Void)?
    /// Called when macOS revokes a permission while the app is running.
    var onPermissionRevoked: ((PermissionCapability) -> Void)?

    public init(
        settingsStore: any SettingsStoring = UserDefaultsSettingsStore(),
        secrets: any SecretStoring = KeychainSecretStore(),
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        permissions: PermissionCenter = PermissionCenter(),
        transcriber: (any SpeechTranscribing)? = nil,
        paths: AppPaths = AppPaths()
    ) {
        // Phase one: everything is computed into locals, because a class cannot
        // touch `self` until every stored property is set.
        var warning: String?
        do {
            try paths.ensureDirectories()
        } catch {
            // The app still works without a writable support directory — it just
            // cannot save transcripts. Say so rather than failing to launch.
            warning = AppError.wrapping(error).errorDescription
        }

        let providerCatalog = ProviderCatalog.standard(transport: transport)
        var loaded = settingsStore.load()
        // Keep the "has a key" mirror honest: the user may have deleted the
        // Keychain item, or restored preferences onto a different Mac.
        loaded.providersWithStoredKey = Set(
            providerCatalog.descriptors
                .map(\.id)
                .filter { secrets.hasSecret(forKey: SecretKey.chatProvider($0)) }
        )
        let snapshot = SettingsSnapshot(loaded)

        self.paths = paths
        self.startupWarning = warning
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.transport = transport
        self.permissions = permissions
        self.providerCatalog = providerCatalog
        self.searchCatalog = SearchCatalog.standard(transport: transport)
        self.speaker = AVSpeechSpeaker()
        self.transcriber = transcriber ?? AppleSpeechTranscriber()
        self.settings = loaded
        self.settingsSnapshot = snapshot
        self.conversationStore = Self.makeConversationStore(
            saveConversations: loaded.saveConversations,
            directory: paths.conversationsDirectory
        )
        // The capture service reads settings through the snapshot at capture
        // time, so toggling screen awareness takes effect with nothing rebuilt.
        self.screenCapturer = ScreenCaptureService(
            encoder: CapturedImageEncoder(byteBudget: loaded.maxImageBytes),
            settingsProvider: { snapshot.value }
        )

        // Phase two: `self` is now usable.
        paths.purgeTemporaryCaptures()
        permissions.onRevocation { [weak self] capability in
            self?.onPermissionRevoked?(capability)
        }
        applyRetentionPolicy()
    }

    /// Thread-safe snapshot of settings for non-main-actor consumers.
    private let settingsSnapshot: SettingsSnapshot

    // MARK: - Secrets

    public func apiKey(forProvider id: String) -> String? {
        try? secrets.secret(forKey: SecretKey.chatProvider(id))
    }

    public func setAPIKey(_ key: String, forProvider id: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.removeSecret(forKey: SecretKey.chatProvider(id))
            settings.providersWithStoredKey.remove(id)
        } else {
            try secrets.setSecret(trimmed, forKey: SecretKey.chatProvider(id))
            settings.providersWithStoredKey.insert(id)
        }
    }

    public func searchAPIKey(forProvider id: String) -> String? {
        try? secrets.secret(forKey: SecretKey.searchProvider(id))
    }

    public func setSearchAPIKey(_ key: String, forProvider id: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.removeSecret(forKey: SecretKey.searchProvider(id))
        } else {
            try secrets.setSecret(trimmed, forKey: SecretKey.searchProvider(id))
        }
    }

    // MARK: - Factories

    /// Builds the chat provider for the current settings, or throws the reason
    /// it cannot be built (no key, unknown model).
    public func makeChatProvider() throws -> any ChatModelProviding {
        try providerCatalog.validate(providerID: settings.chatProviderID, modelID: settings.chatModelID)
        return try providerCatalog.makeProvider(
            id: settings.chatProviderID,
            apiKey: apiKey(forProvider: settings.chatProviderID)
        )
    }

    public func makeSearchProvider() -> any WebSearchProviding {
        searchCatalog.makeProvider(
            id: settings.webSearchProviderID,
            apiKey: searchAPIKey(forProvider: settings.webSearchProviderID),
            webAccessEnabled: settings.webAccessEnabled
        )
    }

    public func makeToolContext() -> ToolContext {
        ToolContext(
            search: makeSearchProvider(),
            clipboard: PasteboardClipboardWriter(),
            urlOpener: WorkspaceURLOpener(),
            noteWriter: FileNoteWriter(directory: paths.notesDirectory),
            maxWebResults: settings.maxWebResults
        )
    }

    public func makeToolRunner(extraTools: [any AssistantTool] = []) -> ToolRunner {
        ToolRunner(
            tools: ToolRunner.standardTools(extra: extraTools),
            confirmer: InteractiveToolConfirmer(center: toolConfirmations)
        )
    }

    // MARK: - Data management

    /// Wipes every transcript and note, and forgets every API key.
    public func deleteAllStoredData() throws {
        try conversationStore.deleteAll()
        try paths.deleteAllStoredData()
        try secrets.removeAllSecrets()
        settings.providersWithStoredKey.removeAll()
    }

    public func deleteAllConversations() throws {
        try conversationStore.deleteAll()
    }

    public func storedDataDescription() -> String {
        let bytes = paths.storedByteCount()
        guard bytes > 0 else { return "Nothing is stored on this Mac." }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let count = (try? conversationStore.summaries().count) ?? 0
        let conversations = count == 1 ? "1 conversation" : "\(count) conversations"
        return "\(conversations), \(formatter.string(fromByteCount: Int64(bytes))) on disk."
    }

    /// Applies the retention setting. `.untilQuit` is handled on termination.
    public func applyRetentionPolicy(now: Date = Date()) {
        guard let maxAge = settings.conversationRetention.maxAge, maxAge > 0 else { return }
        _ = try? conversationStore.pruneOlderThan(maxAge, now: now)
    }

    /// Called from the app delegate on quit.
    public func handleTermination() {
        paths.purgeTemporaryCaptures()
        speaker.stop()
        transcriber.cancel()
        if settings.conversationRetention == .untilQuit {
            try? conversationStore.deleteAll()
        }
    }

    // MARK: - Reactions

    private func persistSettings() {
        settingsSnapshot.value = settings
        do {
            try settingsStore.save(settings)
        } catch {
            startupWarning = AppError.wrapping(error).errorDescription
        }
    }

    private func reactToSettingsChange(from old: AppSettings) {
        if old.saveConversations != settings.saveConversations {
            conversationStore = Self.makeConversationStore(
                saveConversations: settings.saveConversations,
                directory: paths.conversationsDirectory
            )
        }
        if old.screenAwarenessEnabled && !settings.screenAwarenessEnabled {
            onScreenAwarenessDisabled?()
        }
        if !settings.speakResponses && speaker.isSpeaking {
            speaker.stop()
        }
        if old.conversationRetention != settings.conversationRetention {
            applyRetentionPolicy()
        }
        if old.togglePanelShortcut != settings.togglePanelShortcut
            || old.voiceInputShortcut != settings.voiceInputShortcut
            || old.captureRegionShortcut != settings.captureRegionShortcut {
            hotKeys.register(settings: settings)
        }
    }

    private static func makeConversationStore(
        saveConversations: Bool,
        directory: URL
    ) -> any ConversationStoring {
        guard saveConversations else { return NullConversationStore() }
        // If the store cannot be created, fall back to keeping nothing rather
        // than crashing — the user loses history, not the app.
        return (try? FileConversationStore(directory: directory)) ?? NullConversationStore()
    }
}

/// A lock-protected copy of settings, readable from any isolation domain.
///
/// The capture service is an actor and cannot reach into the main-actor
/// environment; this gives it the current values without a hop.
final class SettingsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AppSettings

    init(_ settings: AppSettings) {
        self.storage = settings
    }

    var value: AppSettings {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
