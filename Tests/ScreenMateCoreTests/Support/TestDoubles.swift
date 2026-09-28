import Foundation
@testable import ScreenMateCore

/// Replays canned responses so provider parsing can be tested without a socket.
final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Stub {
        var lines: [String]
        var body: Data
        var metadata: HTTPResponseMetadata

        static func sse(_ lines: [String], statusCode: Int = 200) -> Stub {
            Stub(
                lines: lines,
                body: Data(),
                metadata: HTTPResponseMetadata(
                    statusCode: statusCode,
                    headers: ["Content-Type": "text/event-stream"]
                )
            )
        }

        static func json(_ string: String, statusCode: Int = 200, headers: [String: String] = [:]) -> Stub {
            Stub(
                lines: [string],
                body: Data(string.utf8),
                metadata: HTTPResponseMetadata(
                    statusCode: statusCode,
                    headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first }
                )
            )
        }
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private(set) var recordedRequests: [URLRequest] = []
    /// Thrown instead of answering, to exercise transport failures.
    var errorToThrow: (any Error)?

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    convenience init(stub: Stub) {
        self.init(stubs: [stub])
    }

    private func nextStub(for request: URLRequest) throws -> Stub {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        if let errorToThrow { throw errorToThrow }
        guard !stubs.isEmpty else {
            throw AppError.malformedProviderResponse(detail: "MockHTTPTransport ran out of stubs")
        }
        // The last stub repeats, so multi-round tool loops need only one entry.
        return stubs.count == 1 ? stubs[0] : stubs.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseMetadata) {
        let stub = try nextStub(for: request)
        return (stub.body, stub.metadata)
    }

    func stream(
        _ request: URLRequest
    ) async throws -> (AsyncThrowingStream<String, any Error>, HTTPResponseMetadata) {
        let stub = try nextStub(for: request)
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            for line in stub.lines { continuation.yield(line) }
            continuation.finish()
        }
        return (stream, stub.metadata)
    }

    /// Decodes a recorded request body so tests can assert on the wire format.
    func decodedBody(at index: Int = 0) throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard index < recordedRequests.count, let data = recordedRequests[index].httpBody else {
            throw AppError.malformedProviderResponse(detail: "no recorded body at \(index)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

final class SpyClipboard: ClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var written: [String] = []
    var errorToThrow: (any Error)?

    func write(_ text: String) throws -> Int {
        if let errorToThrow { throw errorToThrow }
        lock.lock(); defer { lock.unlock() }
        written.append(text)
        return text.count
    }
}

final class SpyURLOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened: [URL] = []

    func open(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        opened.append(url)
    }
}

final class SpyNoteWriter: NoteWriting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var notes: [String] = []

    func writeNote(title: String, body: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        notes.append(title)
        return "/tmp/\(title).md"
    }
}

/// Counts confirmation prompts and answers them with a fixed verdict.
final class StubToolConfirmer: ToolConfirming, @unchecked Sendable {
    private let lock = NSLock()
    private let verdict: Bool
    private(set) var requests: [ToolConfirmationRequest] = []

    init(approve: Bool) { self.verdict = approve }

    func confirm(_ request: ToolConfirmationRequest) async -> Bool {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return verdict
    }
}

final class StubSearchProvider: WebSearchProviding, @unchecked Sendable {
    let id = "stub"
    let displayName = "Stub Search"
    let requiresAPIKey = false
    let apiKeyHelpURL: URL? = nil

    private let lock = NSLock()
    private(set) var queries: [String] = []
    var results: [WebSearchResult]
    var errorToThrow: (any Error)?

    init(results: [WebSearchResult] = [], errorToThrow: (any Error)? = nil) {
        self.results = results
        self.errorToThrow = errorToThrow
    }

    func search(query: String, maxResults: Int) async throws -> WebSearchResponse {
        lock.lock()
        queries.append(query)
        lock.unlock()
        if let errorToThrow { throw errorToThrow }
        return WebSearchResponse(
            query: query,
            results: Array(results.prefix(maxResults)),
            retrievedAt: Date(timeIntervalSince1970: 1_700_000_000),
            providerDisplayName: displayName
        )
    }
}

extension ToolContext {
    /// A context whose ports are all spies, for tool tests.
    static func testing(
        search: any WebSearchProviding = StubSearchProvider(),
        clipboard: any ClipboardWriting = SpyClipboard(),
        urlOpener: any URLOpening = SpyURLOpener(),
        noteWriter: any NoteWriting = SpyNoteWriter(),
        maxWebResults: Int = 5,
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ToolContext {
        ToolContext(
            search: search,
            clipboard: clipboard,
            urlOpener: urlOpener,
            noteWriter: noteWriter,
            maxWebResults: maxWebResults,
            now: { now }
        )
    }
}

/// A provider whose reply is fully scripted, including tool calls, so the
/// engine's tool loop can be tested deterministically.
final class ScriptedChatProvider: ChatModelProviding, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    let requiresAPIKey = false
    let models: [AIModel]

    /// One entry per round trip.
    struct Round {
        var text: String
        var toolCalls: [AIToolCall]
        var error: AppError?

        init(text: String = "", toolCalls: [AIToolCall] = [], error: AppError? = nil) {
            self.text = text
            self.toolCalls = toolCalls
            self.error = error
        }
    }

    private let lock = NSLock()
    private var rounds: [Round]
    private(set) var receivedRequests: [AIChatRequest] = []

    init(rounds: [Round], supportsVision: Bool = true, supportsTools: Bool = true) {
        self.rounds = rounds
        self.models = [
            AIModel(
                id: "scripted-1",
                displayName: "Scripted",
                supportsVision: supportsVision,
                supportsTools: supportsTools
            )
        ]
    }

    func streamChat(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, any Error> {
        lock.lock()
        receivedRequests.append(request)
        let round = rounds.isEmpty ? Round(text: "(no more scripted rounds)") : rounds.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            if let error = round.error {
                continuation.finish(throwing: error)
                return
            }
            if !round.text.isEmpty {
                continuation.yield(.textDelta(round.text))
            }
            for call in round.toolCalls {
                continuation.yield(.toolCall(call))
            }
            continuation.yield(.finished(round.toolCalls.isEmpty ? .endTurn : .toolUse))
            continuation.finish()
        }
    }
}

// MARK: - Fixtures

extension ScreenContext {
    static func fixture(
        extractedText: String? = "Console output: error TS2345",
        bytes: Int = 1024,
        findings: [RedactionFinding] = []
    ) -> ScreenContext {
        ScreenContext(
            kind: .window,
            imageData: Data(repeating: 0x42, count: bytes),
            mimeType: "image/png",
            pixelWidth: 1440,
            pixelHeight: 900,
            backingScaleFactor: 2,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceDescription: "Xcode — Built-in Retina Display",
            sourceBundleIdentifier: "com.apple.dt.Xcode",
            extractedText: extractedText,
            redactionFindings: findings
        )
    }
}

extension Conversation {
    static func fixture(userText: String = "What am I looking at?") -> Conversation {
        Conversation(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "New conversation",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            messages: [
                ChatMessage(
                    role: .user,
                    text: userText,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    source: .typed
                )
            ]
        )
    }
}
