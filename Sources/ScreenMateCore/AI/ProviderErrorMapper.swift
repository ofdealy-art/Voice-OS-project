import Foundation

/// Turns an HTTP status plus a provider error body into an `AppError`.
///
/// Shared by every provider so that a 429 from OpenAI and a 429 from Anthropic
/// produce the same user-facing message and the same retry hint.
public struct ProviderErrorMapper: Sendable {
    public let providerDisplayName: String

    public init(providerDisplayName: String) {
        self.providerDisplayName = providerDisplayName
    }

    public func error(
        for metadata: HTTPResponseMetadata,
        body: String?,
        requestedModel: String?
    ) -> AppError {
        let detail = Self.extractMessage(from: body)

        switch metadata.statusCode {
        case 401, 403:
            return .invalidAPIKey(provider: providerDisplayName)
        case 404:
            if let requestedModel {
                return .modelUnavailable(model: requestedModel)
            }
            return .providerUnavailable(status: 404, detail: detail)
        case 413:
            // The provider will not say how big is too big, so report it as what
            // the user can act on rather than inventing a limit.
            return .providerUnavailable(status: 413, detail: detail ?? "the request was too large")
        case 422, 400:
            // A 400 with a model-shaped complaint is almost always a bad model id.
            if let detail, let requestedModel,
               detail.localizedCaseInsensitiveContains("model") {
                return .modelUnavailable(model: requestedModel)
            }
            return .providerUnavailable(status: metadata.statusCode, detail: detail)
        case 429:
            return .rateLimited(retryAfter: metadata.retryAfterSeconds)
        case 500...599:
            return .providerUnavailable(status: metadata.statusCode, detail: detail)
        case 0:
            return .networkUnavailable
        default:
            return .providerUnavailable(status: metadata.statusCode, detail: detail)
        }
    }

    /// Pulls a human-readable sentence out of the error envelopes used by the
    /// providers ScreenMate ships with, falling back to the raw body.
    static func extractMessage(from body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        guard let data = body.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return String(body.prefix(300))
        }
        // { "error": { "message": "…" } } — OpenAI and Anthropic both use this.
        if let message = json["error"]?["message"]?.stringValue { return message }
        if let message = json["error"]?.stringValue { return message }
        if let message = json["message"]?.stringValue { return message }
        if let detail = json["detail"]?.stringValue { return detail }
        return String(body.prefix(300))
    }
}
