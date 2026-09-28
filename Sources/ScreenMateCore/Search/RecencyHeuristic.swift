import Foundation

/// Cheap signal for "this question probably needs today's facts".
///
/// The model still decides whether to call `web_search`; this only adds a line
/// to the system prompt nudging it to, which measurably reduces the case where a
/// model answers a "latest…" question from stale memory. It never triggers a
/// search on its own, and it is skipped entirely when web access is off.
public struct RecencyHeuristic: Sendable {
    private static let cues: [String] = [
        "latest", "newest", "current", "currently", "right now", "today",
        "yesterday", "this week", "this month", "this year", "so far",
        "recent", "recently", "up to date", "up-to-date", "as of",
        "news", "release notes", "changelog", "stock price", "share price",
        "who won", "score", "weather", "forecast", "release date",
        "still", "deprecated", "version",
    ]

    public init() {}

    public func likelyNeedsFreshInformation(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if Self.cues.contains(where: { lowered.contains($0) }) { return true }
        // A year at or after the current one is a strong recency signal.
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        for year in currentYear...(currentYear + 1) where lowered.contains(String(year)) {
            return true
        }
        return false
    }
}
