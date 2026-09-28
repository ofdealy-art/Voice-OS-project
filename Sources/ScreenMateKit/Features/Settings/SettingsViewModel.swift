import AppKit
import Combine
import Foundation
import ScreenMateCore

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case provider
    case voice
    case privacy
    case web
    case general

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .provider: return "Provider"
        case .voice: return "Voice"
        case .privacy: return "Privacy"
        case .web: return "Web"
        case .general: return "General"
        }
    }

    public var systemImage: String {
        switch self {
        case .provider: return "cpu"
        case .voice: return "waveform"
        case .privacy: return "hand.raised"
        case .web: return "globe"
        case .general: return "gearshape"
        }
    }
}

/// Backs the settings window.
///
/// API keys are read from and written to the Keychain on demand; the draft field
/// holds the typed value only until it is saved, and is cleared afterwards so a
/// key is not left sitting in view-model memory.
@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var selectedTab: SettingsTab
    @Published public var chatKeyDraft: String = ""
    @Published public var searchKeyDraft: String = ""
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var storedDataDescription: String = ""
    @Published public private(set) var unavailableShortcuts: Set<HotKeyAction> = []
    @Published public var isConfirmingDataDeletion = false

    public let environment: AppEnvironment

    public init(environment: AppEnvironment, tab: SettingsTab = .provider) {
        self.environment = environment
        self.selectedTab = tab
        refreshStoredDataDescription()
    }

    public var settings: AppSettings {
        get { environment.settings }
        set { environment.settings = newValue }
    }

    // MARK: - Provider

    public var providers: [ProviderDescriptor] { environment.providerCatalog.descriptors }

    public var selectedProvider: ProviderDescriptor? {
        environment.providerCatalog.descriptor(for: settings.chatProviderID)
    }

    public var availableModels: [AIModel] { selectedProvider?.models ?? [] }

    public var hasStoredChatKey: Bool {
        settings.providersWithStoredKey.contains(settings.chatProviderID)
    }

    public func selectProvider(_ id: String) {
        guard let descriptor = environment.providerCatalog.descriptor(for: id) else { return }
        environment.settings.chatProviderID = id
        // Switching provider invalidates the model, so move to its first one
        // rather than leaving a model the new provider does not have.
        if !descriptor.models.contains(where: { $0.id == settings.chatModelID }) {
            environment.settings.chatModelID = descriptor.models.first?.id ?? ""
        }
        chatKeyDraft = ""
        clearMessages()
    }

    public func saveChatKey() {
        let provider = settings.chatProviderID
        do {
            try environment.setAPIKey(chatKeyDraft, forProvider: provider)
            let name = selectedProvider?.displayName ?? provider
            statusMessage = chatKeyDraft.isEmpty
                ? "Removed the \(name) key from your Keychain."
                : "Saved the \(name) key to your Keychain."
            errorMessage = nil
        } catch {
            errorMessage = AppError.wrapping(error).errorDescription
        }
        // Never keep the key in memory after it is stored.
        chatKeyDraft = ""
    }

    public func removeChatKey() {
        chatKeyDraft = ""
        saveChatKey()
    }

    /// Sends one tiny request to confirm the key and model actually work.
    public func testConnection() async {
        clearMessages()
        statusMessage = "Checking…"
        do {
            let provider = try environment.makeChatProvider()
            let request = AIChatRequest(
                model: settings.chatModelID,
                system: "Reply with the single word: ready",
                turns: [.message(.text(.user, "ready?"))],
                maxOutputTokens: 16,
                temperature: 0
            )
            let (text, _) = try await provider.completeChat(request)
            statusMessage = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Connected, but the model returned nothing."
                : "Connected. \(selectedProvider?.displayName ?? "The provider") replied."
        } catch {
            let appError = AppError.wrapping(error)
            statusMessage = nil
            errorMessage = [appError.errorDescription, appError.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    // MARK: - Voice

    public var microphones: [AudioInputDevice] { environment.audioDevices.inputDevices() }

    public var voices: [SpeechVoice] {
        environment.speaker.voices(matching: settings.speechRecognitionLocaleIdentifier)
    }

    /// Locales `SFSpeechRecognizer` can actually handle on this Mac.
    public var speechLocales: [SpeechLocaleOption] {
        SpeechLocaleCatalog.supported()
    }

    public func previewVoice() {
        do {
            try environment.speaker.speak(
                "This is how ScreenMate will read replies aloud.",
                voiceIdentifier: settings.textToSpeechVoiceIdentifier,
                rate: settings.speechRate
            )
        } catch {
            errorMessage = AppError.wrapping(error).errorDescription
        }
    }

    public func stopPreview() {
        environment.speaker.stop()
    }

    // MARK: - Web

    public var searchProviders: [SearchProviderDescriptor] { environment.searchCatalog.descriptors }

    public var selectedSearchProvider: SearchProviderDescriptor? {
        environment.searchCatalog.descriptor(for: settings.webSearchProviderID)
    }

    public var hasStoredSearchKey: Bool {
        environment.secrets.hasSecret(forKey: SecretKey.searchProvider(settings.webSearchProviderID))
    }

    public func saveSearchKey() {
        do {
            try environment.setSearchAPIKey(searchKeyDraft, forProvider: settings.webSearchProviderID)
            let name = selectedSearchProvider?.displayName ?? settings.webSearchProviderID
            statusMessage = searchKeyDraft.isEmpty
                ? "Removed the \(name) key."
                : "Saved the \(name) key to your Keychain."
            errorMessage = nil
        } catch {
            errorMessage = AppError.wrapping(error).errorDescription
        }
        searchKeyDraft = ""
    }

    // MARK: - Permissions

    public func permissionState(_ capability: PermissionCapability) -> PermissionState {
        environment.permissions.state(of: capability)
    }

    public func requestPermission(_ capability: PermissionCapability) {
        Task { @MainActor in
            let result = await environment.permissions.request(capability)
            if result.isGranted && capability.needsRelaunchAfterGranting {
                statusMessage = "\(capability.displayName) granted. Quit and reopen ScreenMate for macOS to apply it."
            }
        }
    }

    public func openPermissionSettings(_ capability: PermissionCapability) {
        environment.permissions.openSystemSettings(for: capability)
    }

    public func refreshPermissions() {
        environment.permissions.refresh()
    }

    // MARK: - Data

    public func refreshStoredDataDescription() {
        storedDataDescription = environment.storedDataDescription()
    }

    public func deleteAllConversations() {
        do {
            try environment.deleteAllConversations()
            statusMessage = "Deleted every saved conversation."
            errorMessage = nil
        } catch {
            errorMessage = AppError.wrapping(error).errorDescription
        }
        refreshStoredDataDescription()
    }

    public func deleteEverything() {
        do {
            try environment.deleteAllStoredData()
            statusMessage = "Deleted all conversations, notes and API keys."
            errorMessage = nil
        } catch {
            errorMessage = AppError.wrapping(error).errorDescription
        }
        isConfirmingDataDeletion = false
        refreshStoredDataDescription()
    }

    public func revealDataFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: environment.paths.supportDirectory.path)
    }

    // MARK: - Shortcuts

    public func applyShortcuts() {
        unavailableShortcuts = Set(environment.hotKeys.register(settings: environment.settings))
        if !unavailableShortcuts.isEmpty {
            errorMessage = "Another app already uses one of those shortcuts. Pick a different combination."
        }
    }

    // MARK: - Startup

    public func setLaunchAtLogin(_ enabled: Bool) {
        environment.settings.launchAtLogin = enabled
        do {
            try LoginItemController.setEnabled(enabled)
            statusMessage = enabled
                ? "ScreenMate will open when you log in."
                : "ScreenMate will no longer open at login."
        } catch {
            environment.settings.launchAtLogin = !enabled
            errorMessage = AppError.wrapping(error).errorDescription
        }
    }

    public func clearMessages() {
        statusMessage = nil
        errorMessage = nil
    }
}

/// One entry in the language picker. A named type rather than a tuple, because
/// `ForEach` needs a key path and Swift has none for tuple elements.
public struct SpeechLocaleOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The speech locales the installed recognisers support, with readable names.
enum SpeechLocaleCatalog {
    static func supported() -> [SpeechLocaleOption] {
        let display = Locale.current
        return SpeechRecognitionSupport.supportedLocaleIdentifiers()
            .map { identifier in
                SpeechLocaleOption(
                    id: identifier,
                    name: display.localizedString(forIdentifier: identifier) ?? identifier
                )
            }
            .sorted { $0.name < $1.name }
    }
}
