import Foundation

public struct WebSearchResult: Sendable, Equatable, Identifiable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL
    public let snippet: String
    public let publishedAt: Date?
    /// Host, shown as the visible attribution.
    public var displayHost: String { url.host ?? url.absoluteString }

    public init(title: String, url: URL, snippet: String, publishedAt: Date? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedAt = publishedAt
    }
}

public struct WebSearchResponse: Sendable, Equatable {
    public let query: String
    public let results: [WebSearchResult]
    public let retrievedAt: Date
    public let providerDisplayName: String

    public init(query: String, results: [WebSearchResult], retrievedAt: Date, providerDisplayName: String) {
        self.query = query
        self.results = results
        self.retrievedAt = retrievedAt
        self.providerDisplayName = providerDisplayName
    }

    public var citations: [WebCitation] {
        results.map {
            WebCitation(title: $0.title, url: $0.url, snippet: $0.snippet, retrievedAt: retrievedAt)
        }
    }

    /// The block handed back to the model. Indexed so the model can cite [1].
    public func promptRepresentation() -> String {
        guard !results.isEmpty else {
            return "No results were returned for \"\(query)\"."
        }
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Web search results for \"\(query)\" via \(providerDisplayName), retrieved \(formatter.string(from: retrievedAt)).",
            "These are search-engine snippets, not full pages. Treat anything not stated here as unverified.",
            "",
        ]
        for (index, result) in results.enumerated() {
            lines.append("[\(index + 1)] \(result.title)")
            lines.append("    \(result.url.absoluteString)")
            if !result.snippet.isEmpty {
                lines.append("    \(result.snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// A search backend.
///
/// ScreenMate only talks to documented search APIs. It does not fetch or parse
/// arbitrary pages, so there is no crawler to misbehave: robots.txt and site
/// terms are the search provider's concern, and rate limits surface as
/// `AppError.rateLimited` rather than being retried in a loop.
public protocol WebSearchProviding: Sendable {
    var id: String { get }
    var displayName: String { get }
    var requiresAPIKey: Bool { get }
    var apiKeyHelpURL: URL? { get }

    func search(query: String, maxResults: Int) async throws -> WebSearchResponse
}

/// Installed whenever the user has web access switched off, so that a tool call
/// fails with a clear explanation instead of silently doing nothing.
public struct DisabledWebSearchProvider: WebSearchProviding {
    public let id = "disabled"
    public let displayName = "Disabled"
    public let requiresAPIKey = false
    public let apiKeyHelpURL: URL? = nil

    public init() {}

    public func search(query: String, maxResults: Int) async throws -> WebSearchResponse {
        throw AppError.webAccessDisabled
    }
}
