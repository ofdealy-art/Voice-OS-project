import AVFoundation
import Foundation
import Speech
import ScreenMateCore

public enum TranscriptionEvent: Sendable, Equatable {
    /// Microphone level, 0…1, for the waveform.
    case level(Float)
    case partial(String)
    case final(String)
}

/// Speech-to-text.
///
/// A protocol so the voice controller can be driven by a fake in tests; the
/// shipping implementation is `AppleSpeechTranscriber`. Swapping in Whisper or a
/// cloud recogniser later means adding one file, not touching the UI.
@MainActor
public protocol SpeechTranscribing: AnyObject {
    /// Opens the microphone and starts recognising. The returned stream ends
    /// after `.final`, or throws an `AppError`.
    func start(
        locale: Locale,
        preferOnDevice: Bool,
        microphoneUID: String?
    ) throws -> AsyncThrowingStream<TranscriptionEvent, any Error>

    /// Closes the microphone and asks for the final result.
    func stop()

    /// Closes the microphone and abandons the result.
    func cancel()
}

/// `SFSpeechRecognizer` + `AVAudioEngine`.
///
/// Live partial results while the user talks, an RMS level for the waveform, and
/// a hard stop that closes the input node — the microphone is never left open
/// after `stop()` or `cancel()`.
@MainActor
public final class AppleSpeechTranscriber: SpeechTranscribing {
    private let engine = AVAudioEngine()
    private let deviceCatalog = AudioDeviceCatalog()

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation?
    private var isRunning = false
    /// Latest partial, so `stop()` can still produce something if the recogniser
    /// never delivers a final result.
    private var latestTranscript = ""

    public init() {}

    public var isMicrophoneOpen: Bool { isRunning }

    public func start(
        locale: Locale,
        preferOnDevice: Bool,
        microphoneUID: String?
    ) throws -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        // Starting twice would leave an orphaned tap on the input node.
        if isRunning { cancel() }

        guard deviceCatalog.hasAnyInput else {
            throw AppError.noAudioInputDevice
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppError.speechRecognitionUnavailable(locale: locale.identifier)
        }
        guard recognizer.isAvailable else {
            // Usually means offline with no on-device model for this language.
            throw AppError.speechRecognitionUnavailable(locale: locale.identifier)
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if preferOnDevice && recognizer.supportsOnDeviceRecognition {
            // Keeps audio on the Mac. Only set when supported: forcing it
            // otherwise makes recognition fail outright.
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        latestTranscript = ""

        let inputNode = engine.inputNode

        // Pick the microphone before reading the input format: the format
        // belongs to the device.
        if let microphoneUID, let device = deviceCatalog.device(forUID: microphoneUID) {
            do {
                try inputNode.auAudioUnit.setDeviceID(device.deviceID)
            } catch {
                // Not fatal — fall back to the system default input rather than
                // refusing to record.
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AppError.noAudioInputDevice
        }

        let stream = AsyncThrowingStream<TranscriptionEvent, any Error> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.teardownAudio() }
            }
        }

        // The continuation is Sendable, so the audio thread can publish through
        // it directly; nothing else is shared with the tap.
        let sink = self.continuation
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            if let level = Self.normalizedLevel(of: buffer) {
                sink?.yield(.level(level))
            }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownAudio()
            throw AppError.speechRecognitionFailed(detail: error.localizedDescription)
        }
        isRunning = true
        return stream
    }

    public func stop() {
        guard isRunning else { return }
        // Close the microphone first, then ask for the final transcription. The
        // recogniser finishes with whatever audio it already has.
        closeMicrophone()
        request?.endAudio()
        task?.finish()

        // If the recogniser never reports back (it can go quiet when the audio
        // held no speech), fall back to the last partial after a short grace
        // period so the UI is never stuck in "finalizing".
        let pending = latestTranscript
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, self.continuation != nil else { return }
            self.finish(with: pending)
        }
    }

    public func cancel() {
        closeMicrophone()
        task?.cancel()
        request?.endAudio()
        let sink = continuation
        continuation = nil
        teardownAudio()
        sink?.finish()
    }

    // MARK: - Private

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: (any Error)?) {
        guard continuation != nil else { return }

        if let result {
            let transcript = result.bestTranscription.formattedString
            latestTranscript = transcript
            if result.isFinal {
                finish(with: transcript)
                return
            }
            continuation?.yield(.partial(transcript))
            return
        }

        guard let error else { return }
        let nsError = error as NSError
        // 1110 / 203 are "no speech detected", which is not a failure worth a red
        // banner — the state machine treats an empty transcript as "nothing heard".
        if nsError.code == 1110 || nsError.code == 203 {
            finish(with: latestTranscript)
            return
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            let sink = continuation
            continuation = nil
            teardownAudio()
            sink?.finish()
            return
        }
        let sink = continuation
        continuation = nil
        teardownAudio()
        sink?.finish(throwing: AppError.speechRecognitionFailed(detail: nsError.localizedDescription))
    }

    private func finish(with transcript: String) {
        let sink = continuation
        continuation = nil
        teardownAudio()
        sink?.yield(.final(transcript))
        sink?.finish()
    }

    /// Stops pulling audio. Split out from `teardownAudio` because `stop()` has
    /// to close the mic before the recogniser has finished.
    private func closeMicrophone() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func teardownAudio() {
        closeMicrophone()
        task = nil
        request = nil
        recognizer = nil
    }

    /// RMS amplitude mapped onto 0…1 for the waveform.
    static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }

        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()

        // Speech sits around -40…0 dBFS; anything quieter reads as silence.
        let decibels = 20 * log10(max(rms, 1e-7))
        let normalized = (decibels + 50) / 50
        return min(max(normalized, 0), 1)
    }
}
