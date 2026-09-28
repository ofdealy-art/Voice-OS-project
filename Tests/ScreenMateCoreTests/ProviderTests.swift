import XCTest
@testable import ScreenMateCore

final class ServerSentEventParserTests: XCTestCase {
    func testParsesNamedEventWithData() {
        let events = ServerSentEventParser.parseAll(lines: [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta"}"#,
            "",
        ])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "content_block_delta")
        XCTAssertEqual(events[0].data, #"{"type":"content_block_delta"}"#)
    }

    func testJoinsMultipleDataLines() {
        let events = ServerSentEventParser.parseAll(lines: ["data: {", "data: }", ""])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "{\n}")
    }

    func testIgnoresCommentsAndHeartbeats() {
        let events = ServerSentEventParser.parseAll(lines: [": ping", "", "data: hello", ""])
        XCTAssertEqual(events.map(\.data), ["hello"])
    }

    func testFlushesTrailingEventWithoutBlankLine() {
        let events = ServerSentEventParser.parseAll(lines: ["data: tail"])
        XCTAssertEqual(events.map(\.data), ["tail"])
    }

    func testRecognisesDoneSentinel() {
        let events = ServerSentEventParser.parseAll(lines: ["data: [DONE]", ""])
        XCTAssertTrue(events[0].isDoneSentinel)
    }
}

final class AnthropicProviderTests: XCTestCase {
    private func stream(_ events: [String]) -> [String] {
        events.flatMap { [$0, ""] }
    }

    func testStreamsTextDeltas() async throws {
        let transport = MockHTTPTransport(stub: .sse(stream([
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"You are"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" looking at Xcode."}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#,
        ])))
        let provider = AnthropicChatProvider(apiKey: "test-key", transport: transport)

        var text = ""
        var usages: [AIUsage] = []
        var stopReason: AIStopReason?
        for try await event in provider.streamChat(request()) {
            switch event {
            case .textDelta(let delta): text += delta
            case .usage(let usage): usages.append(usage)
            case .finished(let reason): stopReason = reason
            case .toolCall: XCTFail("unexpected tool call")
            }
        }

        XCTAssertEqual(text, "You are looking at Xcode.")
        XCTAssertEqual(usages.first?.inputTokens, 12)
        XCTAssertEqual(usages.last?.outputTokens, 7)
        XCTAssertEqual(stopReason, .endTurn)
    }

    func testAssemblesFragmentedToolCall() async throws {
        let transport = MockHTTPTransport(stub: .sse(stream([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"web_search"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"swift"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":" 6 release date\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ])))
        let provider = AnthropicChatProvider(apiKey: "test-key", transport: transport)

        var calls: [AIToolCall] = []
        for try await event in provider.streamChat(request()) {
            if case .toolCall(let call) = event { calls.append(call) }
        }

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "toolu_1")
        XCTAssertEqual(calls[0].name, "web_search")
        XCTAssertEqual(calls[0].arguments["query"]?.stringValue, "swift 6 release date")
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let transport = MockHTTPTransport(stub: .sse([]))
        let provider = AnthropicChatProvider(apiKey: "", transport: transport)
        await assertThrows(AppError.missingAPIKey(provider: "Anthropic")) {
            for try await _ in provider.streamChat(request()) {}
        }
        XCTAssertTrue(transport.recordedRequests.isEmpty)
    }

    func testUnauthorizedBecomesInvalidAPIKey() async {
        let transport = MockHTTPTransport(stub: .json(
            #"{"error":{"message":"invalid x-api-key"}}"#,
            statusCode: 401
        ))
        let provider = AnthropicChatProvider(apiKey: "bad", transport: transport)
        await assertThrows(AppError.invalidAPIKey(provider: "Anthropic")) {
            for try await _ in provider.streamChat(request()) {}
        }
    }

    func testRateLimitCarriesRetryAfter() async {
        let transport = MockHTTPTransport(stub: .json(
            #"{"error":{"message":"slow down"}}"#,
            statusCode: 429,
            headers: ["Retry-After": "30"]
        ))
        let provider = AnthropicChatProvider(apiKey: "key", transport: transport)
        await assertThrows(AppError.rateLimited(retryAfter: 30)) {
            for try await _ in provider.streamChat(request()) {}
        }
    }

    func testNotFoundBecomesModelUnavailable() async {
        let transport = MockHTTPTransport(stub: .json(#"{"error":{"message":"no such model"}}"#, statusCode: 404))
        let provider = AnthropicChatProvider(apiKey: "key", transport: transport)
        await assertThrows(AppError.modelUnavailable(model: "claude-sonnet-5")) {
            for try await _ in provider.streamChat(request()) {}
        }
    }

    func testMidStreamErrorEventSurfaces() async {
        let transport = MockHTTPTransport(stub: .sse(stream([
            #"data: {"type":"error","error":{"message":"overloaded"}}"#,
        ])))
        let provider = AnthropicChatProvider(apiKey: "key", transport: transport)
        await assertThrows(AppError.providerUnavailable(status: 200, detail: "overloaded")) {
            for try await _ in provider.streamChat(request()) {}
        }
    }

    func testEncodesImageAsBase64Source() throws {
        let turns: [AITurn] = [
            .message(AIRequestMessage(role: .user, parts: [
                .image(AIImagePayload(data: Data([0x01, 0x02]), mimeType: "image/png")),
                .text("What is this?"),
            ]))
        ]
        let encoded = AnthropicChatProvider.encodeTurns(turns)
        let content = encoded[0]["content"]?.arrayValue
        XCTAssertEqual(content?[0]["type"]?.stringValue, "image")
        XCTAssertEqual(content?[0]["source"]?["media_type"]?.stringValue, "image/png")
        XCTAssertEqual(content?[0]["source"]?["data"]?.stringValue, Data([0x01, 0x02]).base64EncodedString())
        XCTAssertEqual(content?[1]["text"]?.stringValue, "What is this?")
    }

    func testEncodesToolResultAsUserBlock() throws {
        let turns: [AITurn] = [.toolResults([
            AIToolResult(callID: "toolu_1", name: "web_search", content: "results here")
        ])]
        let encoded = AnthropicChatProvider.encodeTurns(turns)
        XCTAssertEqual(encoded[0]["role"]?.stringValue, "user")
        XCTAssertEqual(encoded[0]["content"]?.arrayValue?[0]["type"]?.stringValue, "tool_result")
        XCTAssertEqual(encoded[0]["content"]?.arrayValue?[0]["tool_use_id"]?.stringValue, "toolu_1")
    }

    func testSystemPromptIsSentOutOfBand() async throws {
        let transport = MockHTTPTransport(stub: .sse(stream([
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ])))
        let provider = AnthropicChatProvider(apiKey: "key", transport: transport)
        for try await _ in provider.streamChat(request(system: "Be brief.")) {}

        let body = try transport.decodedBody()
        XCTAssertEqual(body["system"]?.stringValue, "Be brief.")
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(transport.recordedRequests[0].value(forHTTPHeaderField: "x-api-key"), "key")
        XCTAssertEqual(
            transport.recordedRequests[0].value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01"
        )
    }

    private func request(system: String = "") -> AIChatRequest {
        AIChatRequest(
            model: "claude-sonnet-5",
            system: system,
            turns: [.message(.text(.user, "hello"))]
        )
    }
}

final class OpenAIProviderTests: XCTestCase {
    func testStreamsDeltasAndFinishReason() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#, "",
            #"data: {"choices":[{"delta":{"content":" there"}}]}"#, "",
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, "",
            "data: [DONE]", "",
        ]
        let provider = OpenAIChatProvider(apiKey: "key", transport: MockHTTPTransport(stub: .sse(lines)))

        var text = ""
        var reason: AIStopReason?
        for try await event in provider.streamChat(request()) {
            switch event {
            case .textDelta(let delta): text += delta
            case .finished(let value): reason = value
            default: break
            }
        }
        XCTAssertEqual(text, "Hello there")
        XCTAssertEqual(reason, .endTurn)
    }

    func testAssemblesToolCallAcrossDeltas() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"open_url","arguments":""}}]}}]}"#, "",
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"url\":\"https://exa"}}]}}]}"#, "",
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"mple.com\"}"}}]}}]}"#, "",
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "",
        ]
        let provider = OpenAIChatProvider(apiKey: "key", transport: MockHTTPTransport(stub: .sse(lines)))

        var calls: [AIToolCall] = []
        for try await event in provider.streamChat(request()) {
            if case .toolCall(let call) = event { calls.append(call) }
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "open_url")
        XCTAssertEqual(calls[0].arguments["url"]?.stringValue, "https://example.com")
    }

    func testSingleTextPartIsSentAsBareString() {
        let encoded = OpenAIChatProvider.encodeTurns([.message(.text(.user, "hi"))])
        XCTAssertEqual(encoded[0]["content"]?.stringValue, "hi")
    }

    func testImageIsSentAsDataURL() {
        let encoded = OpenAIChatProvider.encodeTurns([
            .message(AIRequestMessage(role: .user, parts: [
                .image(AIImagePayload(data: Data([0xFF]), mimeType: "image/jpeg")),
                .text("look"),
            ]))
        ])
        let url = encoded[0]["content"]?.arrayValue?[0]["image_url"]?["url"]?.stringValue
        XCTAssertEqual(url, "data:image/jpeg;base64,\(Data([0xFF]).base64EncodedString())")
    }

    func testToolArgumentsAreSerialisedAsAString() throws {
        let encoded = OpenAIChatProvider.encodeTurns([
            .assistantToolCalls(text: nil, calls: [
                AIToolCall(id: "call_1", name: "web_search", arguments: .object(["query": "swift"]))
            ])
        ])
        let arguments = encoded[0]["tool_calls"]?.arrayValue?[0]["function"]?["arguments"]?.stringValue
        XCTAssertEqual(arguments, #"{"query":"swift"}"#)
    }

    func testCustomBaseURLEnablesLocalModels() async throws {
        let transport = MockHTTPTransport(stub: .sse([#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#, ""]))
        let provider = OpenAIChatProvider(
            apiKey: "",
            transport: transport,
            baseURL: URL(string: "http://localhost:11434")!,
            id: "local",
            displayName: "Local model",
            requiresAPIKey: false,
            models: [AIModel(id: "llama3.2-vision", displayName: "Llama 3.2 Vision", supportsVision: true)]
        )
        for try await _ in provider.streamChat(
            AIChatRequest(model: "llama3.2-vision", system: "", turns: [.message(.text(.user, "hi"))])
        ) {}
        XCTAssertEqual(
            transport.recordedRequests[0].url?.absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
        XCTAssertNil(transport.recordedRequests[0].value(forHTTPHeaderField: "Authorization"))
    }

    private func request() -> AIChatRequest {
        AIChatRequest(model: "gpt-4o", system: "", turns: [.message(.text(.user, "hello"))])
    }
}

final class ProviderCatalogTests: XCTestCase {
    private let transport = MockHTTPTransport(stub: .sse([]))

    func testSwitchingProviderYieldsADifferentImplementation() throws {
        let catalog = ProviderCatalog.standard(transport: transport)
        let anthropic = try catalog.makeProvider(id: "anthropic", apiKey: "k")
        let openAI = try catalog.makeProvider(id: "openai", apiKey: "k")
        XCTAssertEqual(anthropic.id, "anthropic")
        XCTAssertEqual(openAI.id, "openai")
        XCTAssertTrue(anthropic is AnthropicChatProvider)
        XCTAssertTrue(openAI is OpenAIChatProvider)
    }

    func testDemoProviderNeedsNoKey() throws {
        let catalog = ProviderCatalog.standard(transport: transport)
        let demo = try catalog.makeProvider(id: "demo", apiKey: nil)
        XCTAssertFalse(demo.requiresAPIKey)
    }

    func testMissingKeyIsReportedBeforeConstruction() {
        let catalog = ProviderCatalog.standard(transport: transport)
        XCTAssertThrowsError(try catalog.makeProvider(id: "anthropic", apiKey: nil)) { error in
            XCTAssertEqual(error as? AppError, .missingAPIKey(provider: "Anthropic"))
        }
    }

    func testUnknownProviderIsRejected() {
        let catalog = ProviderCatalog.standard(transport: transport)
        XCTAssertThrowsError(try catalog.makeProvider(id: "nope", apiKey: "k"))
    }

    func testValidateRejectsAModelTheProviderDoesNotHave() {
        let catalog = ProviderCatalog.standard(transport: transport)
        XCTAssertThrowsError(try catalog.validate(providerID: "anthropic", modelID: "gpt-4o")) { error in
            XCTAssertEqual(error as? AppError, .modelUnavailable(model: "gpt-4o"))
        }
        XCTAssertNoThrow(try catalog.validate(providerID: "anthropic", modelID: "claude-sonnet-5"))
    }
}

// MARK: - Helper

extension XCTestCase {
    /// Asserts that `body` throws a specific `AppError`.
    func assertThrows(
        _ expected: AppError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected) but nothing was thrown", file: file, line: line)
        } catch let error as AppError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected) but got \(error)", file: file, line: line)
        }
    }
}
