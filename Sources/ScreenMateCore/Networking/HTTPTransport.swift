import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponseMetadata: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }

    /// Case-insensitive header lookup; servers are inconsistent about casing.
    public func header(_ name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }

    public var retryAfterSeconds: TimeInterval? {
        guard let raw = header("retry-after") else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) { return seconds }
        // Retry-After may also be an HTTP date.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Seam between providers and the network, so provider parsing can be tested
/// against recorded bytes with no sockets involved.
public protocol HTTPTransport: Sendable {
    /// Buffered request/response.
    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseMetadata)

    /// Line-oriented streaming response, for `text/event-stream`.
    ///
    /// The metadata is returned as soon as headers arrive so a caller can fail
    /// fast on a 401 without waiting for a body.
    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, any Error>, HTTPResponseMetadata)
}

// `URLSession.bytes(for:)` is a Darwin-only API; swift-corelibs-foundation has
// no `AsyncBytes`. The protocol above is what the rest of the app depends on, so
// non-Darwin builds (used to run the ScreenMateCore test suite in CI) simply do
// not get this concrete transport.
#if canImport(Darwin)
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPResponseMetadata) {
        let (data, response) = try await session.data(for: request)
        return (data, Self.metadata(from: response))
    }

    public func stream(
        _ request: URLRequest
    ) async throws -> (AsyncThrowingStream<String, any Error>, HTTPResponseMetadata) {
        let (bytes, response) = try await session.bytes(for: request)
        let metadata = Self.metadata(from: response)

        guard metadata.isSuccess else {
            // Drain the (small) error body so the caller can report the reason.
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64 * 1024 { break }
            }
            let text = String(decoding: body, as: UTF8.self)
            let stream = AsyncThrowingStream<String, any Error> { continuation in
                continuation.yield(text)
                continuation.finish()
            }
            return (stream, metadata)
        }

        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, metadata)
    }

    private static func metadata(from response: URLResponse) -> HTTPResponseMetadata {
        guard let http = response as? HTTPURLResponse else {
            return HTTPResponseMetadata(statusCode: 0)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponseMetadata(statusCode: http.statusCode, headers: headers)
    }
}
#endif
