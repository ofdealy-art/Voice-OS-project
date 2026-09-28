import Foundation

public enum VoiceState: Equatable, Sendable {
    case idle
    case requestingPermission
    case permissionDenied(AppError)
    /// Microphone is open. `level` is 0…1 for the waveform.
    case listening(level: Float, partialTranscript: String)
    /// Microphone closed, waiting for the final transcription.
    case finalizing(partialTranscript: String)
    case failed(AppError)

    public var isMicrophoneOpen: Bool {
        if case .listening = self { return true }
        return false
    }

    public var partialTranscript: String {
        switch self {
        case .listening(_, let text), .finalizing(let text): return text
        default: return ""
        }
    }

    public var level: Float {
        if case .listening(let level, _) = self { return level }
        return 0
    }
}

public enum VoiceEvent: Equatable, Sendable {
    /// User pressed the mic button or the hotkey.
    case startRequested(hasPermission: Bool)
    case permissionGranted
    case permissionRefused(AppError)
    case engineStarted
    case levelChanged(Float)
    case partialTranscript(String)
    /// Push-to-talk release, hands-free silence timeout, or the stop button.
    case stopRequested
    case finalTranscript(String)
    case recognizerFailed(AppError)
    /// User pressed Escape or the cancel button; the transcript is thrown away.
    case cancelRequested
}

/// What the owning view model should actually do. Returned rather than performed
/// so the transition table can be tested without an audio engine.
public enum VoiceEffect: Equatable, Sendable {
    case requestPermission
    case startEngine
    case stopEngine
    /// Discard audio and transcript without submitting anything.
    case discard
    /// Hand the transcript to the chat layer.
    case submit(String)
    case announce(String)
}

/// The voice input lifecycle.
///
/// Extracted from the view model because the interesting bugs in voice UI are all
/// ordering bugs — a stop arriving before the engine started, a final transcript
/// after a cancel — and those are only testable if the transitions are pure.
public struct VoiceSessionMachine: Sendable {
    public private(set) var state: VoiceState = .idle
    /// Set by `cancelRequested` so a late final transcript is dropped.
    private var discardNextTranscript = false

    public init() {}

    @discardableResult
    public mutating func handle(_ event: VoiceEvent) -> [VoiceEffect] {
        switch (state, event) {

        // MARK: Starting
        case (.idle, .startRequested(let hasPermission)),
             (.failed, .startRequested(let hasPermission)),
             (.permissionDenied, .startRequested(let hasPermission)):
            discardNextTranscript = false
            if hasPermission {
                state = .listening(level: 0, partialTranscript: "")
                return [.startEngine, .announce("Listening")]
            }
            state = .requestingPermission
            return [.requestPermission]

        case (.requestingPermission, .permissionGranted):
            state = .listening(level: 0, partialTranscript: "")
            return [.startEngine, .announce("Listening")]

        case (.requestingPermission, .permissionRefused(let error)):
            state = .permissionDenied(error)
            return [.announce(error.errorDescription ?? "Microphone unavailable")]

        // Ignore a second start while already live, rather than restarting the
        // engine underneath an in-progress recording.
        case (.listening, .startRequested), (.finalizing, .startRequested), (.requestingPermission, .startRequested):
            return []

        case (.listening, .engineStarted):
            return []

        // MARK: Live updates
        case (.listening(_, let transcript), .levelChanged(let level)):
            state = .listening(level: max(0, min(1, level)), partialTranscript: transcript)
            return []

        case (.listening(let level, _), .partialTranscript(let text)):
            state = .listening(level: level, partialTranscript: text)
            return []

        // A partial arriving after the mic closed still updates the display.
        case (.finalizing, .partialTranscript(let text)):
            state = .finalizing(partialTranscript: text)
            return []

        // MARK: Stopping
        case (.listening(_, let transcript), .stopRequested):
            state = .finalizing(partialTranscript: transcript)
            return [.stopEngine]

        case (.finalizing, .stopRequested):
            return [] // Already stopping.

        case (.finalizing, .finalTranscript(let text)):
            state = .idle
            if discardNextTranscript {
                discardNextTranscript = false
                return [.discard]
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return [.announce("Nothing was heard")]
            }
            return [.submit(trimmed)]

        // Some recognisers deliver the final result while the engine is still
        // running (hands-free mode); treat it as stop-then-submit.
        case (.listening, .finalTranscript(let text)):
            state = .idle
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return [.stopEngine, .announce("Nothing was heard")]
            }
            return [.stopEngine, .submit(trimmed)]

        // MARK: Cancelling
        case (.listening, .cancelRequested), (.finalizing, .cancelRequested):
            discardNextTranscript = true
            state = .idle
            return [.stopEngine, .discard, .announce("Voice input cancelled")]

        case (.requestingPermission, .cancelRequested):
            state = .idle
            return [.announce("Voice input cancelled")]

        // MARK: Failures
        case (_, .recognizerFailed(let error)):
            state = .failed(error)
            return [.stopEngine, .discard, .announce(error.errorDescription ?? "Speech recognition failed")]

        case (_, .permissionRefused(let error)):
            state = .permissionDenied(error)
            return [.stopEngine, .announce(error.errorDescription ?? "Microphone unavailable")]

        // MARK: Ignored
        default:
            return []
        }
    }

    /// Called when macOS revokes microphone access mid-session.
    public mutating func permissionRevoked() -> [VoiceEffect] {
        handle(.permissionRefused(.permissionRevokedWhileRunning(capability: "Microphone")))
    }
}
