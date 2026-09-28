import Foundation

public enum AppearanceTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum VoiceInputMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Microphone is live only while the button or hotkey is held.
    case pushToTalk
    /// Microphone stays live until the user stops it or silence is detected.
    case handsFree

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .handsFree: return "Hands-free"
        }
    }
}

public enum ScreenCaptureScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case activeDisplay
    case activeWindow
    case selectedRegion

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .activeDisplay: return "Whole display"
        case .activeWindow: return "Front window"
        case .selectedRegion: return "Selected region"
        }
    }
}

public enum ConversationRetention: String, Codable, Sendable, CaseIterable, Identifiable {
    case untilQuit
    case sevenDays
    case thirtyDays
    case forever

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .untilQuit: return "Until I quit ScreenMate"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .forever: return "Keep until I delete them"
        }
    }

    /// `nil` means "never expires on a timer".
    public var maxAge: TimeInterval? {
        switch self {
        case .untilQuit: return 0
        case .sevenDays: return 7 * 24 * 60 * 60
        case .thirtyDays: return 30 * 24 * 60 * 60
        case .forever: return nil
        }
    }
}

/// A recorded keyboard shortcut. Stored as raw Carbon/AppKit values so that it
/// round-trips through JSON without depending on AppKit in this target.
public struct KeyboardShortcut: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    /// AppKit `NSEvent.ModifierFlags` raw value, masked to device-independent bits.
    public var modifierFlags: UInt
    /// Pre-rendered glyphs, e.g. "⌥⌘Space". Computed by the recorder in the UI layer.
    public var displayString: String

    public init(keyCode: UInt32, modifierFlags: UInt, displayString: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.displayString = displayString
    }

    /// ⌥⌘Space — toggles the panel. `keyCode` 49 is Space.
    public static let defaultToggle = KeyboardShortcut(
        keyCode: 49,
        modifierFlags: 0x0008_0000 | 0x0010_0000, // option | command
        displayString: "⌥⌘Space"
    )

    /// ⌥⌘V — starts voice input. `keyCode` 9 is V.
    public static let defaultVoice = KeyboardShortcut(
        keyCode: 9,
        modifierFlags: 0x0008_0000 | 0x0010_0000,
        displayString: "⌥⌘V"
    )

    /// ⌥⌘S — captures a region of the screen. `keyCode` 1 is S.
    public static let defaultCapture = KeyboardShortcut(
        keyCode: 1,
        modifierFlags: 0x0008_0000 | 0x0010_0000,
        displayString: "⌥⌘S"
    )
}

/// All user preferences.
///
/// Secrets are *not* here — API keys live in the Keychain, keyed by provider
/// id, and this struct only records which providers have one configured.
public struct AppSettings: Codable, Sendable, Equatable {
    // MARK: Provider
    public var chatProviderID: String
    public var chatModelID: String
    /// Providers the user has entered a key for. Mirrors the Keychain so the UI
    /// can render state without a Keychain round-trip on every redraw.
    public var providersWithStoredKey: Set<String>
    public var maxOutputTokens: Int
    public var temperature: Double

    // MARK: Voice
    public var voiceInputMode: VoiceInputMode
    public var speechRecognitionLocaleIdentifier: String
    public var preferOnDeviceSpeechRecognition: Bool
    public var selectedMicrophoneUID: String?
    public var speakResponses: Bool
    public var textToSpeechVoiceIdentifier: String?
    /// 0…1 in `AVSpeechUtterance` terms; 0.5 is the system default rate.
    public var speechRate: Double
    public var interruptSpeechWhenUserSpeaks: Bool
    public var handsFreeSilenceTimeout: TimeInterval

    // MARK: Screen awareness
    public var screenAwarenessEnabled: Bool
    public var sendScreenContentToProvider: Bool
    public var defaultCaptureScope: ScreenCaptureScope
    public var runOCROnCaptures: Bool
    public var redactSensitiveContent: Bool
    public var skipCaptureForSensitiveApps: Bool
    public var alwaysPreviewBeforeSending: Bool
    public var maxImageBytes: Int

    // MARK: Web
    public var webAccessEnabled: Bool
    public var webSearchProviderID: String
    public var maxWebResults: Int

    // MARK: Window & input
    public var alwaysOnTop: Bool
    public var launchAtLogin: Bool
    public var showInMenuBar: Bool
    public var togglePanelShortcut: KeyboardShortcut
    public var voiceInputShortcut: KeyboardShortcut
    public var captureRegionShortcut: KeyboardShortcut
    public var theme: AppearanceTheme
    /// Saved panel origin in screen coordinates, so the widget reappears where
    /// the user left it.
    public var widgetOriginX: Double?
    public var widgetOriginY: Double?

    // MARK: Privacy
    public var saveConversations: Bool
    public var conversationRetention: ConversationRetention
    public var hasCompletedOnboarding: Bool
    /// Off by default and never turned on automatically. Present so that the
    /// setting can be shown as "off" rather than being absent.
    public var analyticsEnabled: Bool

    public init(
        chatProviderID: String = "anthropic",
        chatModelID: String = "claude-sonnet-5",
        providersWithStoredKey: Set<String> = [],
        maxOutputTokens: Int = 2048,
        temperature: Double = 0.7,
        voiceInputMode: VoiceInputMode = .pushToTalk,
        speechRecognitionLocaleIdentifier: String = "en-US",
        preferOnDeviceSpeechRecognition: Bool = true,
        selectedMicrophoneUID: String? = nil,
        speakResponses: Bool = true,
        textToSpeechVoiceIdentifier: String? = nil,
        speechRate: Double = 0.5,
        interruptSpeechWhenUserSpeaks: Bool = true,
        handsFreeSilenceTimeout: TimeInterval = 1.6,
        screenAwarenessEnabled: Bool = false,
        sendScreenContentToProvider: Bool = false,
        defaultCaptureScope: ScreenCaptureScope = .activeWindow,
        runOCROnCaptures: Bool = true,
        redactSensitiveContent: Bool = true,
        skipCaptureForSensitiveApps: Bool = true,
        alwaysPreviewBeforeSending: Bool = true,
        maxImageBytes: Int = 4 * 1024 * 1024,
        webAccessEnabled: Bool = false,
        webSearchProviderID: String = "brave",
        maxWebResults: Int = 5,
        alwaysOnTop: Bool = true,
        launchAtLogin: Bool = false,
        showInMenuBar: Bool = true,
        togglePanelShortcut: KeyboardShortcut = .defaultToggle,
        voiceInputShortcut: KeyboardShortcut = .defaultVoice,
        captureRegionShortcut: KeyboardShortcut = .defaultCapture,
        theme: AppearanceTheme = .system,
        widgetOriginX: Double? = nil,
        widgetOriginY: Double? = nil,
        saveConversations: Bool = true,
        conversationRetention: ConversationRetention = .thirtyDays,
        hasCompletedOnboarding: Bool = false,
        analyticsEnabled: Bool = false
    ) {
        self.chatProviderID = chatProviderID
        self.chatModelID = chatModelID
        self.providersWithStoredKey = providersWithStoredKey
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.voiceInputMode = voiceInputMode
        self.speechRecognitionLocaleIdentifier = speechRecognitionLocaleIdentifier
        self.preferOnDeviceSpeechRecognition = preferOnDeviceSpeechRecognition
        self.selectedMicrophoneUID = selectedMicrophoneUID
        self.speakResponses = speakResponses
        self.textToSpeechVoiceIdentifier = textToSpeechVoiceIdentifier
        self.speechRate = speechRate
        self.interruptSpeechWhenUserSpeaks = interruptSpeechWhenUserSpeaks
        self.handsFreeSilenceTimeout = handsFreeSilenceTimeout
        self.screenAwarenessEnabled = screenAwarenessEnabled
        self.sendScreenContentToProvider = sendScreenContentToProvider
        self.defaultCaptureScope = defaultCaptureScope
        self.runOCROnCaptures = runOCROnCaptures
        self.redactSensitiveContent = redactSensitiveContent
        self.skipCaptureForSensitiveApps = skipCaptureForSensitiveApps
        self.alwaysPreviewBeforeSending = alwaysPreviewBeforeSending
        self.maxImageBytes = maxImageBytes
        self.webAccessEnabled = webAccessEnabled
        self.webSearchProviderID = webSearchProviderID
        self.maxWebResults = maxWebResults
        self.alwaysOnTop = alwaysOnTop
        self.launchAtLogin = launchAtLogin
        self.showInMenuBar = showInMenuBar
        self.togglePanelShortcut = togglePanelShortcut
        self.voiceInputShortcut = voiceInputShortcut
        self.captureRegionShortcut = captureRegionShortcut
        self.theme = theme
        self.widgetOriginX = widgetOriginX
        self.widgetOriginY = widgetOriginY
        self.saveConversations = saveConversations
        self.conversationRetention = conversationRetention
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.analyticsEnabled = analyticsEnabled
    }

    /// Screen pixels may only leave the Mac when *both* switches are on. Checked
    /// at the single point where a request is assembled, not at the UI layer.
    public var mayShareScreenWithProvider: Bool {
        screenAwarenessEnabled && sendScreenContentToProvider
    }

    // MARK: Decoding tolerance
    //
    // Every property has a default, and decoding falls back to it when a key is
    // missing. That lets an older settings file load into a newer build without
    // wiping the user's preferences.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }
        func optional<T: Decodable>(_ key: CodingKeys) -> T? {
            try? container.decodeIfPresent(T.self, forKey: key)
        }

        self.chatProviderID = value(.chatProviderID, fallback.chatProviderID)
        self.chatModelID = value(.chatModelID, fallback.chatModelID)
        self.providersWithStoredKey = value(.providersWithStoredKey, fallback.providersWithStoredKey)
        self.maxOutputTokens = value(.maxOutputTokens, fallback.maxOutputTokens)
        self.temperature = value(.temperature, fallback.temperature)
        self.voiceInputMode = value(.voiceInputMode, fallback.voiceInputMode)
        self.speechRecognitionLocaleIdentifier = value(.speechRecognitionLocaleIdentifier, fallback.speechRecognitionLocaleIdentifier)
        self.preferOnDeviceSpeechRecognition = value(.preferOnDeviceSpeechRecognition, fallback.preferOnDeviceSpeechRecognition)
        self.selectedMicrophoneUID = optional(.selectedMicrophoneUID)
        self.speakResponses = value(.speakResponses, fallback.speakResponses)
        self.textToSpeechVoiceIdentifier = optional(.textToSpeechVoiceIdentifier)
        self.speechRate = value(.speechRate, fallback.speechRate)
        self.interruptSpeechWhenUserSpeaks = value(.interruptSpeechWhenUserSpeaks, fallback.interruptSpeechWhenUserSpeaks)
        self.handsFreeSilenceTimeout = value(.handsFreeSilenceTimeout, fallback.handsFreeSilenceTimeout)
        self.screenAwarenessEnabled = value(.screenAwarenessEnabled, fallback.screenAwarenessEnabled)
        self.sendScreenContentToProvider = value(.sendScreenContentToProvider, fallback.sendScreenContentToProvider)
        self.defaultCaptureScope = value(.defaultCaptureScope, fallback.defaultCaptureScope)
        self.runOCROnCaptures = value(.runOCROnCaptures, fallback.runOCROnCaptures)
        self.redactSensitiveContent = value(.redactSensitiveContent, fallback.redactSensitiveContent)
        self.skipCaptureForSensitiveApps = value(.skipCaptureForSensitiveApps, fallback.skipCaptureForSensitiveApps)
        self.alwaysPreviewBeforeSending = value(.alwaysPreviewBeforeSending, fallback.alwaysPreviewBeforeSending)
        self.maxImageBytes = value(.maxImageBytes, fallback.maxImageBytes)
        self.webAccessEnabled = value(.webAccessEnabled, fallback.webAccessEnabled)
        self.webSearchProviderID = value(.webSearchProviderID, fallback.webSearchProviderID)
        self.maxWebResults = value(.maxWebResults, fallback.maxWebResults)
        self.alwaysOnTop = value(.alwaysOnTop, fallback.alwaysOnTop)
        self.launchAtLogin = value(.launchAtLogin, fallback.launchAtLogin)
        self.showInMenuBar = value(.showInMenuBar, fallback.showInMenuBar)
        self.togglePanelShortcut = value(.togglePanelShortcut, fallback.togglePanelShortcut)
        self.voiceInputShortcut = value(.voiceInputShortcut, fallback.voiceInputShortcut)
        self.captureRegionShortcut = value(.captureRegionShortcut, fallback.captureRegionShortcut)
        self.theme = value(.theme, fallback.theme)
        self.widgetOriginX = optional(.widgetOriginX)
        self.widgetOriginY = optional(.widgetOriginY)
        self.saveConversations = value(.saveConversations, fallback.saveConversations)
        self.conversationRetention = value(.conversationRetention, fallback.conversationRetention)
        self.hasCompletedOnboarding = value(.hasCompletedOnboarding, fallback.hasCompletedOnboarding)
        self.analyticsEnabled = value(.analyticsEnabled, fallback.analyticsEnabled)
    }
}
