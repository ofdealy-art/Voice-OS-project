import AVFoundation
import Foundation
import ScreenMateCore

public struct SpeechVoice: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let languageCode: String
    /// Siri and Premium/Enhanced voices; worth marking because the difference is large.
    public let isEnhanced: Bool

    public init(id: String, name: String, languageCode: String, isEnhanced: Bool) {
        self.id = id
        self.name = name
        self.languageCode = languageCode
        self.isEnhanced = isEnhanced
    }

    public var displayName: String {
        isEnhanced ? "\(name) (enhanced)" : name
    }
}

/// Text-to-speech.
///
/// Behind a protocol so a neural TTS backend can replace it without touching the
/// assistant; `AVSpeechSynthesizer` is what ships because it needs no key, no
/// network, and no extra permission.
@MainActor
public protocol SpeechSpeaking: AnyObject {
    var isSpeaking: Bool { get }
    var availableVoices: [SpeechVoice] { get }
    /// Speaks `text`, replacing anything currently being spoken.
    func speak(_ text: String, voiceIdentifier: String?, rate: Double) throws
    func stop()
}

@MainActor
public final class AVSpeechSpeaker: NSObject, SpeechSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// Called when playback ends on its own, so the UI can leave the "speaking"
    /// state without polling.
    public var onFinish: (() -> Void)?
    public var onFailure: ((AppError) -> Void)?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public var availableVoices: [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                SpeechVoice(
                    id: voice.identifier,
                    name: voice.name,
                    languageCode: voice.language,
                    isEnhanced: voice.quality != .default
                )
            }
            .sorted { lhs, rhs in
                if lhs.languageCode == rhs.languageCode { return lhs.name < rhs.name }
                return lhs.languageCode < rhs.languageCode
            }
    }

    /// Voices matching the user's current language, listed first in Settings.
    public func voices(matching localeIdentifier: String) -> [SpeechVoice] {
        let prefix = String(localeIdentifier.prefix(2))
        let all = availableVoices
        let matching = all.filter { $0.languageCode.hasPrefix(prefix) }
        return matching.isEmpty ? all : matching
    }

    /// Declared `throws` so a future backend can report a real failure. The
    /// `AVSpeechSynthesizer` path has nothing synchronous to fail on: the reply is
    /// already on screen, so a silent no-op beats a spurious error banner.
    public func speak(_ text: String, voiceIdentifier: String?, rate: Double) throws {
        let trimmed = Self.spokenText(from: text)
        guard !trimmed.isEmpty else { return }

        // Replacing, not queueing: a new reply should not wait behind the old one.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        // `AVSpeechUtterance` rate is 0…1 with 0.5 as normal; the settings slider
        // uses the same scale so there is nothing to translate.
        utterance.rate = Float(min(max(rate, 0), 1))
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        synthesizer.speak(utterance)
    }

    public func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Strips the markdown that would otherwise be read out character by
    /// character ("hash hash Summary", "star star important star star").
    static func spokenText(from text: String) -> String {
        var result = text

        // Fenced code blocks: say that there is code rather than reading it.
        result = result.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " (code block omitted) ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        // Links: keep the label, drop the URL.
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?m)^#{1,6}\\s*",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s*>\\s*", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s*\\|.*$", with: "", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AVSpeechSynthesizerDelegate
    //
    // These are `nonisolated` because `AVSpeechSynthesizerDelegate` makes no
    // actor guarantees; each one hops to the main actor before touching state.

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}
