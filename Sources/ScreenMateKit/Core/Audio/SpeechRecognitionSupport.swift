import Foundation
import Speech

/// Wraps the one `SFSpeechRecognizer` class method the settings screen needs, so
/// nothing else has to import Speech.
public enum SpeechRecognitionSupport {
    public static func supportedLocaleIdentifiers() -> [String] {
        let identifiers = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        // Some systems report none until a language pack is installed; offer the
        // current locale so the picker is never empty.
        return identifiers.isEmpty ? [Locale.current.identifier] : identifiers.sorted()
    }

    public static func isSupported(_ identifier: String) -> Bool {
        supportedLocaleIdentifiers().contains(identifier)
    }
}
