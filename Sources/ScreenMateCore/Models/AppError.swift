import Foundation

/// Every user-visible failure in ScreenMate funnels through this type so that
/// the UI can always show a plain-language explanation *and* a concrete next
/// step. Nothing in the app is allowed to surface a raw `NSError` description.
public enum AppError: Error, Equatable, Sendable {
    // Configuration
    case missingAPIKey(provider: String)
    case invalidAPIKey(provider: String)
    case modelUnavailable(model: String)
    case unsupportedOSVersion(required: String)

    // Networking / provider
    case networkUnavailable
    case requestTimedOut
    case rateLimited(retryAfter: TimeInterval?)
    case providerUnavailable(status: Int, detail: String?)
    case malformedProviderResponse(detail: String?)
    case cancelled

    // Permissions
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied
    case permissionRevokedWhileRunning(capability: String)

    // Audio / voice
    case noAudioInputDevice
    case speechRecognitionUnavailable(locale: String)
    case speechRecognitionFailed(detail: String?)
    case textToSpeechFailed(detail: String?)

    // Screen
    case screenCaptureFailed(detail: String?)
    case screenCaptureCancelled
    case noCapturableDisplay
    case imageTooLarge(bytes: Int, limit: Int)
    case screenAwarenessDisabled
    case screenSharingWithProviderDisabled

    // Web research
    case webAccessDisabled
    case webSearchNotConfigured(provider: String)
    case webSearchFailed(detail: String?)

    // Input / tools
    case emptyInput
    case toolNotFound(name: String)
    case toolArgumentsInvalid(tool: String, detail: String)
    case toolExecutionFailed(tool: String, detail: String)
    case toolConfirmationDeclined(tool: String)

    // Storage
    case storageFailure(detail: String)
    case keychainFailure(status: Int32)
}

extension AppError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key for \(provider)."
        case .invalidAPIKey(let provider):
            return "\(provider) rejected the API key."
        case .modelUnavailable(let model):
            return "The model \"\(model)\" is not available to this account."
        case .unsupportedOSVersion(let required):
            return "This feature needs \(required) or later."
        case .networkUnavailable:
            return "No network connection."
        case .requestTimedOut:
            return "The request timed out."
        case .rateLimited:
            return "The provider is rate limiting requests."
        case .providerUnavailable(let status, let detail):
            if let detail, !detail.isEmpty {
                return "The provider returned an error (\(status)): \(detail)"
            }
            return "The provider returned an error (\(status))."
        case .malformedProviderResponse:
            return "The provider sent a response ScreenMate could not read."
        case .cancelled:
            return "Stopped."
        case .microphonePermissionDenied:
            return "ScreenMate does not have microphone access."
        case .speechRecognitionPermissionDenied:
            return "ScreenMate does not have speech recognition access."
        case .screenRecordingPermissionDenied:
            return "ScreenMate does not have Screen Recording access."
        case .accessibilityPermissionDenied:
            return "ScreenMate does not have Accessibility access."
        case .permissionRevokedWhileRunning(let capability):
            return "\(capability) access was turned off while ScreenMate was running."
        case .noAudioInputDevice:
            return "No microphone was found."
        case .speechRecognitionUnavailable(let locale):
            return "Speech recognition is not available for \(locale)."
        case .speechRecognitionFailed:
            return "ScreenMate could not transcribe that recording."
        case .textToSpeechFailed:
            return "ScreenMate could not speak the reply."
        case .screenCaptureFailed:
            return "Screen capture failed."
        case .screenCaptureCancelled:
            return "Screen capture cancelled."
        case .noCapturableDisplay:
            return "No display was available to capture."
        case .imageTooLarge(let bytes, let limit):
            return "That image is \(AppError.formatBytes(bytes)), over the \(AppError.formatBytes(limit)) limit."
        case .screenAwarenessDisabled:
            return "Screen awareness is turned off."
        case .screenSharingWithProviderDisabled:
            return "Sending screen content to the AI provider is turned off."
        case .webAccessDisabled:
            return "Web access is turned off."
        case .webSearchNotConfigured(let provider):
            return "\(provider) web search has no API key."
        case .webSearchFailed:
            return "The web search failed."
        case .emptyInput:
            return "Nothing to send."
        case .toolNotFound(let name):
            return "The assistant asked for an unknown tool \"\(name)\"."
        case .toolArgumentsInvalid(let tool, let detail):
            return "The assistant called \"\(tool)\" with unusable arguments: \(detail)"
        case .toolExecutionFailed(let tool, let detail):
            return "\"\(tool)\" failed: \(detail)"
        case .toolConfirmationDeclined(let tool):
            return "\"\(tool)\" was not run."
        case .storageFailure(let detail):
            return "ScreenMate could not save to disk: \(detail)"
        case .keychainFailure:
            return "ScreenMate could not reach the macOS Keychain."
        }
    }

    /// The one thing the user should do next. Shown directly under the message.
    public var recoverySuggestion: String? {
        switch self {
        case .missingAPIKey:
            return "Open Settings › Provider and paste an API key."
        case .invalidAPIKey:
            return "Check the key in Settings › Provider, then try again."
        case .modelUnavailable:
            return "Pick a different model in Settings › Provider."
        case .unsupportedOSVersion:
            return "Update macOS, or use the rest of ScreenMate without this feature."
        case .networkUnavailable:
            return "Reconnect to Wi-Fi or Ethernet and send the message again."
        case .requestTimedOut:
            return "Send the message again. If it keeps timing out, try a smaller screenshot or a shorter prompt."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Wait about \(Int(retryAfter.rounded())) seconds and try again."
            }
            return "Wait a moment and try again."
        case .providerUnavailable, .malformedProviderResponse:
            return "Try again in a minute, or switch provider in Settings."
        case .cancelled:
            return nil
        case .microphonePermissionDenied:
            return "Open System Settings › Privacy & Security › Microphone and turn on ScreenMate."
        case .speechRecognitionPermissionDenied:
            return "Open System Settings › Privacy & Security › Speech Recognition and turn on ScreenMate."
        case .screenRecordingPermissionDenied:
            return "Open System Settings › Privacy & Security › Screen & System Audio Recording and turn on ScreenMate, then quit and reopen the app."
        case .accessibilityPermissionDenied:
            return "Open System Settings › Privacy & Security › Accessibility and turn on ScreenMate. This is optional — ScreenMate works without it."
        case .permissionRevokedWhileRunning:
            return "Turn the permission back on in System Settings, then quit and reopen ScreenMate."
        case .noAudioInputDevice:
            return "Connect a microphone, or pick a different input in Settings › Voice."
        case .speechRecognitionUnavailable:
            return "Choose a different language in Settings › Voice, or type instead."
        case .speechRecognitionFailed:
            return "Try recording again, closer to the microphone — or type the message."
        case .textToSpeechFailed:
            return "Pick a different voice in Settings › Voice. The reply is still shown as text."
        case .screenCaptureFailed:
            return "Try again. If it keeps failing, quit and reopen ScreenMate."
        case .screenCaptureCancelled:
            return nil
        case .noCapturableDisplay:
            return "Make sure at least one display is awake and try again."
        case .imageTooLarge:
            return "Capture a smaller region instead of the whole screen."
        case .screenAwarenessDisabled:
            return "Turn on Screen awareness in Settings › Privacy when you want ScreenMate to look at your screen."
        case .screenSharingWithProviderDisabled:
            return "Turn on \"Send screen content to the AI provider\" in Settings › Privacy. Screen analysis cannot work without it."
        case .webAccessDisabled:
            return "Turn on Web access in Settings › Web to let ScreenMate look things up."
        case .webSearchNotConfigured:
            return "Add a search API key in Settings › Web."
        case .webSearchFailed:
            return "Try a different wording, or answer without web results."
        case .emptyInput:
            return "Type a message or hold the microphone button first."
        case .toolNotFound, .toolArgumentsInvalid:
            return "Ask again in different words. Nothing was changed on your Mac."
        case .toolExecutionFailed:
            return "Try again, or do that step yourself."
        case .toolConfirmationDeclined:
            return nil
        case .storageFailure:
            return "Check that your home folder is writable, or turn off \"Save conversations\" in Settings › Privacy."
        case .keychainFailure:
            return "Unlock your login keychain and try again."
        }
    }

    /// `true` when retrying the exact same request could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .requestTimedOut, .rateLimited,
             .providerUnavailable, .malformedProviderResponse,
             .screenCaptureFailed, .webSearchFailed, .speechRecognitionFailed:
            return true
        default:
            return false
        }
    }

    /// Errors the user caused deliberately; the UI shows these quietly (or not
    /// at all) rather than as a red banner.
    public var isUserInitiated: Bool {
        switch self {
        case .cancelled, .screenCaptureCancelled, .toolConfirmationDeclined, .emptyInput:
            return true
        default:
            return false
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Wraps an arbitrary `Error` into an `AppError` so UI code only has one case
/// tree to reason about.
public extension AppError {
    static func wrapping(_ error: any Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return .cancelled }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .providerUnavailable(status: 0, detail: nsError.localizedDescription)
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return .networkUnavailable
        case NSURLErrorTimedOut:
            return .requestTimedOut
        case NSURLErrorCancelled:
            return .cancelled
        default:
            return .providerUnavailable(status: 0, detail: nsError.localizedDescription)
        }
    }
}
