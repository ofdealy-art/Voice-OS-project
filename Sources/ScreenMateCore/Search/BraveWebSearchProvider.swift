import Foundation

/// Brave Search API.
public struct BraveWebSearchProvider: WebSearchProviding {
    public static let providerID = "brave"

    public let id = BraveWebSearchProvider.providerID
    public let displayName = "Brave Search"
    public let requiresAPIKey = true
    public var apiKeyHelpURL: URL? { URL(string: "https://api-dashboard.search.brave.com/app/keys") }

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let mapper = ProviderErrorMapper(providerDisplayName: "Brave Search")

    public init(
        apiKey: String,
        transport: any HTTPTransport,
        baseURL: URL = URL(string: "https://api.search.brave.com")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public func search(query: String, maxResults: Int) async throws -> WebSearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.emptyInput }
        guard !apiKey.isEmpty else { throw AppError.webSearchNotConfigured(provider: displayName) }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("res/v1/web/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "count", value: String(min(max(maxResults, 1), 20))),
            URLQueryItem(name: "safesearch", value: "moderate"),
        ]
        guard let url = components?.url else {
            throw AppError.webSearchFailed(detail: "the query could not be encoded")
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        let (data, metadata): (Data, HTTPResponseMetadata)
        do {
            (data, metadata) = try await transport.send(request)
        } catch {
            throw AppError.wrapping(error)
        }

        guard metadata.isSuccess else {
            let body = String(decoding: data, as: UTF8.self)
            let mapped = mapper.error(for: metadata, body: body, requestedModel: nil)
            // A bad search key should not read as "your model key is wrong".
            if case .invalidAPIKey = mapped {
                throw AppError.webSearchNotConfigured(provider: displayName)
            }
            if case .rateLimited = mapped { throw mapped }
            throw AppError.webSearchFailed(detail: ProviderErrorMapper.extractMessage(from: body))
        }

        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AppError.webSearchFailed(detail: "the response could not be read")
        }

        let entries = json["web"]?["results"]?.arrayValue ?? []
        let results: [WebSearchResult] = entries.compactMap { entry in
            guard let urlString = entry["url"]?.stringValue,
                  let url = URL(string: urlString),
                  let title = entry["title"]?.stringValue else { return nil }
            return WebSearchResult(
                title: Self.stripMarkup(title),
                url: url,
                snippet: Self.stripMarkup(entry["description"]?.stringValue ?? ""),
                publishedAt: nil
            )
        }

        return WebSearchResponse(
            query: trimmed,
            results: Array(results.prefix(maxResults)),
            retrievedAt: Date(),
            providerDisplayName: displayName
        )
    }

    /// Brave marks query terms with `<strong>`; the model does not need that.
    static func stripMarkup(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
