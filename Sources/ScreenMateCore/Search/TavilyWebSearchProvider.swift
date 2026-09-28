import Foundation

/// Tavily Search API — an alternative backend, wired up to prove the search
/// abstraction is real and to give users a second option.
public struct TavilyWebSearchProvider: WebSearchProviding {
    public static let providerID = "tavily"

    public let id = TavilyWebSearchProvider.providerID
    public let displayName = "Tavily"
    public let requiresAPIKey = true
    public var apiKeyHelpURL: URL? { URL(string: "https://app.tavily.com/home") }

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        apiKey: String,
        transport: any HTTPTransport,
        baseURL: URL = URL(string: "https://api.tavily.com")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public func search(query: String, maxResults: Int) async throws -> WebSearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.emptyInput }
        guard !apiKey.isEmpty else { throw AppError.webSearchNotConfigured(provider: displayName) }

        var request = URLRequest(url: baseURL.appendingPathComponent("search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "query": .string(trimmed),
            "max_results": .number(Double(min(max(maxResults, 1), 20))),
            "search_depth": "basic",
            "include_answer": .bool(false),
            "include_raw_content": .bool(false),
        ]))

        let (data, metadata): (Data, HTTPResponseMetadata)
        do {
            (data, metadata) = try await transport.send(request)
        } catch {
            throw AppError.wrapping(error)
        }

        guard metadata.isSuccess else {
            let body = String(decoding: data, as: UTF8.self)
            switch metadata.statusCode {
            case 401, 403:
                throw AppError.webSearchNotConfigured(provider: displayName)
            case 429:
                throw AppError.rateLimited(retryAfter: metadata.retryAfterSeconds)
            default:
                throw AppError.webSearchFailed(detail: ProviderErrorMapper.extractMessage(from: body))
            }
        }

        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AppError.webSearchFailed(detail: "the response could not be read")
        }

        let results: [WebSearchResult] = (json["results"]?.arrayValue ?? []).compactMap { entry in
            guard let urlString = entry["url"]?.stringValue,
                  let url = URL(string: urlString) else { return nil }
            return WebSearchResult(
                title: entry["title"]?.stringValue ?? url.absoluteString,
                url: url,
                snippet: entry["content"]?.stringValue ?? "",
                publishedAt: entry["published_date"]?.stringValue.flatMap {
                    ISO8601DateFormatter().date(from: $0)
                }
            )
        }

        return WebSearchResponse(
            query: trimmed,
            results: Array(results.prefix(maxResults)),
            retrievedAt: Date(),
            providerDisplayName: displayName
        )
    }
}
