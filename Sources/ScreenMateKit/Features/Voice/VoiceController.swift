import Combine
import Foundation
import ScreenMateCore

/// Drives voice input: owns the state machine, the transcriber, and the timer
/// that ends a hands-free turn after a pause.
///
/// All decisions live in `VoiceSessionMachine` (which is tested); this class only
/// performs the effects the machine asks for.
@MainActor
public final class VoiceController: ObservableObject {
    @Published public private(set) var state: VoiceState = .idle

    /// Emitted when a transcript is ready to send.
    public var onTranscript: ((String) -> Void)?
    /// Emitted for VoiceOver announcements and the status line.
    public var onAnnouncement: ((String) -> Void)?
    /// Called just before the microphone opens, so the assistant can stop talking.
    public var onWillStartListening: (() -> Void)?
    /// Called on every transition, so the assistant's activity indicator matches.
    public var onStateChange: ((VoiceState) -> Void)?

    private var machine = VoiceSessionMachine()
    private let transcriber: any SpeechTranscribing
    private let permissions: PermissionCenter
    private let settingsProvider: () -> AppSettings

    private var listeningTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    /// Level history for the waveform, newest last.
    @Published public private(set) var levels: [Float] = Array(repeating: 0, count: 28)

    public init(
        transcriber: any SpeechTranscribing,
        permissions: PermissionCenter,
        settingsProvider: @escaping () -> AppSettings
    ) {
        self.transcriber = transcriber
        self.permissions = permissions
        self.settingsProvider = settingsProvider
    }

    public var isListening: Bool { state.isMicrophoneOpen }
    public var partialTranscript: String { state.partialTranscript }

    // MARK: - Intent

    public func toggle() {
        if state.isMicrophoneOpen {
            stop()
        } else {
            start()
        }
    }

    public func start() {
        // Talking over the assistant should interrupt it, not compete with it.
        onWillStartListening?()
        apply(machine.handle(.startRequested(hasPermission: permissions.canUseVoice)))
    }

    /// Push-to-talk release, or the stop button.
    public func stop() {
        apply(machine.handle(.stopRequested))
    }

    public func cancel() {
        apply(machine.handle(.cancelRequested))
    }

    /// Called by `PermissionCenter` when access is withdrawn mid-session.
    public func permissionRevoked() {
        apply(machine.permissionRevoked())
    }

    // MARK: - Effects

    private func apply(_ effects: [VoiceEffect]) {
        publish()
        for effect in effects {
            switch effect {
            case .requestPermission:
                requestPermission()
            case .startEngine:
                startEngine()
            case .stopEngine:
                stopEngine()
            case .discard:
                resetLevels()
            case .submit(let transcript):
                resetLevels()
                onTranscript?(transcript)
            case .announce(let message):
                onAnnouncement?(message)
            }
        }
        publish()
    }

    private func publish() {
        guard state != machine.state else { return }
        state = machine.state
        onStateChange?(state)
    }

    private func requestPermission() {
        Task { @MainActor in
            // Microphone first, then speech recognition: both are needed, and
            // asking for them in that order matches what the user expects.
            for capability in [PermissionCapability.microphone, .speechRecognition] {
                let result = await permissions.request(capability)
                guard result.isGranted else {
                    apply(machine.handle(.permissionRefused(capability.missingError)))
                    return
                }
            }
            apply(machine.handle(.permissionGranted))
        }
    }

    private func startEngine() {
        let settings = settingsProvider()
        let locale = Locale(identifier: settings.speechRecognitionLocaleIdentifier)

        let stream: AsyncThrowingStream<TranscriptionEvent, any Error>
        do {
            stream = try transcriber.start(
                locale: locale,
                preferOnDevice: settings.preferOnDeviceSpeechRecognition,
                microphoneUID: settings.selectedMicrophoneUID
            )
        } catch {
            apply(machine.handle(.recognizerFailed(AppError.wrapping(error))))
            return
        }

        listeningTask?.cancel()
        listeningTask = Task { @MainActor in
            do {
                for try await event in stream {
                    switch event {
                    case .level(let level):
                        recordLevel(level)
                        apply(machine.handle(.levelChanged(level)))
                        if settings.voiceInputMode == .handsFree {
                            scheduleSilenceTimeout(level: level, timeout: settings.handsFreeSilenceTimeout)
                        }
                    case .partial(let text):
                        apply(machine.handle(.partialTranscript(text)))
                    case .final(let text):
                        apply(machine.handle(.finalTranscript(text)))
                    }
                }
            } catch {
                apply(machine.handle(.recognizerFailed(AppError.wrapping(error))))
            }
        }
    }

    private func stopEngine() {
        silenceTask?.cancel()
        silenceTask = nil
        // `stop` lets the recogniser finish; `cancel` throws the audio away. Which
        // one depends on whether the machine still wants a transcript.
        switch machine.state {
        case .finalizing:
            transcriber.stop()
        default:
            transcriber.cancel()
            listeningTask?.cancel()
            listeningTask = nil
        }
    }

    /// Hands-free mode: end the turn once the level has been low for long enough.
    private func scheduleSilenceTimeout(level: Float, timeout: TimeInterval) {
        guard level < 0.12 else {
            silenceTask?.cancel()
            silenceTask = nil
            return
        }
        guard silenceTask == nil else { return }
        silenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, self.state.isMicrophoneOpen else { return }
            self.silenceTask = nil
            self.stop()
        }
    }

    private func recordLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    private func resetLevels() {
        levels = Array(repeating: 0, count: levels.count)
    }
}
