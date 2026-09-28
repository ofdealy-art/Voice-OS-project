import Foundation

/// Replaces credentials and payment data in text before it leaves the Mac.
///
/// This is a best-effort safety net, not a guarantee — it works on patterns and
/// will miss secrets that do not look like secrets. The UI says so, and the
/// primary protection remains that screen capture is opt-in and previewed.
/// `@unchecked Sendable` because it stores `NSRegularExpression`, which is not
/// marked `Sendable` but is documented as safe for concurrent matching. The rules
/// are built once in `init` and never mutated.
public struct SensitiveTextRedactor: @unchecked Sendable {
    public static let placeholder = "[redacted]"

    private struct Rule {
        let category: RedactionFinding.Category
        let regex: NSRegularExpression
        /// Extra validation beyond the pattern (e.g. Luhn for card numbers).
        let validate: (@Sendable (String) -> Bool)?
    }

    private let rules: [Rule]

    public init() {
        func make(
            _ category: RedactionFinding.Category,
            _ pattern: String,
            options: NSRegularExpression.Options = [],
            validate: (@Sendable (String) -> Bool)? = nil
        ) -> Rule? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                assertionFailure("Invalid redaction pattern: \(pattern)")
                return nil
            }
            return Rule(category: category, regex: regex, validate: validate)
        }

        // Order matters: longer, more specific patterns run first so that a
        // PEM block is not partially eaten by the token rule.
        self.rules = [
            make(
                .privateKey,
                "-----BEGIN[A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END[A-Z ]*PRIVATE KEY-----"
            ),
            make(
                .apiKey,
                // OpenAI/Anthropic/Stripe/GitHub/Slack/Google/AWS style keys.
                "\\b(?:sk-ant-[A-Za-z0-9_\\-]{16,}|sk-[A-Za-z0-9]{20,}|rk_live_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9\\-]{10,}|AIza[A-Za-z0-9_\\-]{30,}|AKIA[0-9A-Z]{16})\\b"
            ),
            make(
                .bearerToken,
                // JWTs and explicit Authorization headers.
                "\\b(?:eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,})\\b"
            ),
            make(
                .bearerToken,
                "(?:Authorization\\s*:\\s*)(?:Bearer|Basic|Token)\\s+[A-Za-z0-9_\\-\\.=+/]{12,}",
                options: [.caseInsensitive]
            ),
            make(
                .passwordAssignment,
                // password: hunter2 / api_secret = "…" / passphrase=…
                "\\b(?:pass(?:word|phrase)|secret|client_secret|api_secret|auth_token|access_token)\\b\\s*[:=]\\s*\\\"?[^\\s\\\"',;]{4,}\\\"?",
                options: [.caseInsensitive]
            ),
            make(
                .paymentCard,
                "\\b(?:\\d[ \\-]?){13,19}\\b",
                validate: { candidate in
                    let digits = candidate.filter(\.isNumber)
                    guard (13...19).contains(digits.count) else { return false }
                    return SensitiveTextRedactor.passesLuhn(digits)
                }
            ),
            make(
                .bankAccount,
                // IBAN: two-letter country code, two check digits, up to 30 alphanumerics.
                "\\b[A-Z]{2}\\d{2}[A-Z0-9]{11,30}\\b",
                validate: { candidate in
                    // Guard against matching ordinary uppercase identifiers.
                    candidate.filter(\.isNumber).count >= 6
                }
            ),
            make(
                .socialSecurityNumber,
                "\\b\\d{3}-\\d{2}-\\d{4}\\b"
            ),
        ].compactMap { $0 }
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        public let findings: [RedactionFinding]

        public init(text: String, findings: [RedactionFinding]) {
            self.text = text
            self.findings = findings
        }

        public var didRedact: Bool { !findings.isEmpty }
    }

    /// Returns `text` with every match replaced by `[redacted]`, plus a tally.
    public func redact(_ text: String) -> Result {
        guard !text.isEmpty else { return Result(text: text, findings: []) }

        var working = text
        var counts: [RedactionFinding.Category: Int] = [:]

        for rule in rules {
            var replaced = ""
            var lastEnd = working.startIndex
            let nsRange = NSRange(working.startIndex..<working.endIndex, in: working)
            let matches = rule.regex.matches(in: working, options: [], range: nsRange)
            guard !matches.isEmpty else { continue }

            for match in matches {
                guard let range = Range(match.range, in: working) else { continue }
                let matched = String(working[range])
                if let validate = rule.validate, !validate(matched) { continue }
                replaced += working[lastEnd..<range.lowerBound]
                replaced += Self.placeholder
                lastEnd = range.upperBound
                counts[rule.category, default: 0] += 1
            }

            guard lastEnd != working.startIndex else { continue }
            replaced += working[lastEnd...]
            working = replaced
        }

        let findings = counts
            .map { RedactionFinding(category: $0.key, count: $0.value) }
            .sorted { $0.category.rawValue < $1.category.rawValue }
        return Result(text: working, findings: findings)
    }

    /// Standard Luhn checksum, used so that long invoice or order numbers are
    /// not mistaken for credit cards.
    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for character in digits.reversed() {
            guard let digit = character.wholeNumberValue else { return false }
            if double {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
            double.toggle()
        }
        return sum % 10 == 0
    }
}
