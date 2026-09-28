import Foundation

/// The single source of truth for "what is the assistant doing right now".
///
/// Both the collapsed widget's indicator and the expanded panel's status row
/// render from this, so the two can never disagree.
public enum AssistantActivity: Equatable, Sendable {
    case idle
    case listening(level: Float)
    case transcribing
    case readingScreen
    case searchingWeb(query: String?)
    case thinking
    case streaming
    case runningTool(name: String)
    case awaitingToolConfirmation(name: String)
    case speaking
    case failed(MessageFailure)

    public var isBusy: Bool {
        switch self {
        case .idle, .failed:
            return false
        default:
            return true
        }
    }

    /// True while the microphone is actually capturing audio. Drives the
    /// "ScreenMate is listening" indicator, which must never be shown when the
    /// microphone is closed.
    public var isCapturingAudio: Bool {
        switch self {
        case .listening, .transcribing:
            return true
        default:
            return false
        }
    }

    /// True while screen pixels are being read. Drives the screen-awareness dot.
    public var isReadingScreen: Bool {
        if case .readingScreen = self { return true }
        return false
    }

    /// True while a request to the provider is in flight and can be stopped.
    public var isInterruptible: Bool {
        switch self {
        case .thinking, .streaming, .searchingWeb, .readingScreen, .runningTool, .speaking, .listening:
            return true
        default:
            return false
        }
    }

    public var shortLabel: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .readingScreen: return "Reading screen"
        case .searchingWeb(let query):
            if let query, !query.isEmpty { return "Searching the web for \"\(query)\"" }
            return "Searching the web"
        case .thinking: return "Thinking"
        case .streaming: return "Replying"
        case .runningTool(let name): return "Running \(name)"
        case .awaitingToolConfirmation(let name): return "Waiting for you to approve \(name)"
        case .speaking: return "Speaking"
        case .failed(let failure): return failure.message
        }
    }

    /// Spoken to VoiceOver users when the state changes.
    public var accessibilityAnnouncement: String {
        switch self {
        case .idle: return "ScreenMate is ready."
        case .listening: return "ScreenMate is listening."
        case .transcribing: return "Transcribing your voice."
        case .readingScreen: return "ScreenMate is reading your screen."
        case .searchingWeb: return "Searching the web."
        case .thinking: return "Thinking."
        case .streaming: return "Reply arriving."
        case .runningTool(let name): return "Running the \(name) action."
        case .awaitingToolConfirmation(let name): return "\(name) needs your approval."
        case .speaking: return "ScreenMate is speaking."
        case .failed(let failure): return "Error. \(failure.message)"
        }
    }
}
