import Foundation

/// Anthropic Messages API provider (streaming, vision, tool use).
public struct AnthropicChatProvider: ChatModelProviding {
    public static let providerID = "anthropic"

    public let id = AnthropicChatProvider.providerID
    public let displayName = "Anthropic"
    public let requiresAPIKey = true
    public var apiKeyHelpURL: URL? { URL(string: "https://console.anthropic.com/settings/keys") }

    public let models: [AIModel] = [
        AIModel(id: "claude-opus-5", displayName: "Claude Opus 5", supportsVision: true),
        AIModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", supportsVision: true),
        AIModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", supportsVision: true),
    ]

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let apiVersion = "2023-06-01"
    private let mapper = ProviderErrorMapper(providerDisplayName: "Anthropic")

    public init(
        apiKey: String,
        transport: any HTTPTransport,
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public func streamChat(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AppError.cancelled)
                } catch {
                    continuation.finish(throwing: AppError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AIChatRequest,
        continuation: AsyncThrowingStream<AIStreamEvent, any Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AppError.missingAPIKey(provider: displayName) }

        let urlRequest = try makeRequest(request)
        let (lines, metadata) = try await transport.stream(urlRequest)

        guard metadata.isSuccess else {
            var body = ""
            for try await line in lines { body += line }
            throw mapper.error(for: metadata, body: body, requestedModel: request.model)
        }

        var parser = ServerSentEventParser()
        var assembler = ToolCallAssembler()

        for try await line in lines {
            try Task.checkCancellation()
            guard let event = parser.consume(line: line) else { continue }
            try handle(event, assembler: &assembler, continuation: continuation)
        }
        if let event = parser.flush() {
            try handle(event, assembler: &assembler, continuation: continuation)
        }
    }

    // MARK: - Request encoding

    private func makeRequest(_ request: AIChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxOutputTokens)),
            "temperature": .number(request.temperature),
            "stream": .bool(true),
            "messages": .array(Self.encodeTurns(request.turns)),
        ]
        if !request.system.isEmpty {
            body["system"] = .string(request.system)
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters,
                ])
            })
        }

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(JSONValue.object(body))
        return urlRequest
    }

    static func encodeTurns(_ turns: [AITurn]) -> [JSONValue] {
        var messages: [JSONValue] = []
        for turn in turns {
            switch turn {
            case .message(let message):
                // Anthropic takes the system prompt out of band; a stray system
                // message is folded into the user turn rather than dropped.
                let role = message.role == .assistant ? "assistant" : "user"
                messages.append(.object([
                    "role": .string(role),
                    "content": .array(message.parts.map(encodePart)),
                ]))

            case .assistantToolCalls(let text, let calls):
                var blocks: [JSONValue] = []
                if let text, !text.isEmpty {
                    blocks.append(.object(["type": "text", "text": .string(text)]))
                }
                for call in calls {
                    blocks.append(.object([
                        "type": "tool_use",
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": call.arguments,
                    ]))
                }
                messages.append(.object(["role": "assistant", "content": .array(blocks)]))

            case .toolResults(let results):
                let blocks: [JSONValue] = results.map { result in
                    .object([
                        "type": "tool_result",
                        "tool_use_id": .string(result.callID),
                        "content": .string(result.content),
                        "is_error": .bool(result.isError),
                    ])
                }
                messages.append(.object(["role": "user", "content": .array(blocks)]))
            }
        }
        return messages
    }

    private static func encodePart(_ part: AIContentPart) -> JSONValue {
        switch part {
        case .text(let text):
            return .object(["type": "text", "text": .string(text)])
        case .image(let image):
            return .object([
                "type": "image",
                "source": .object([
                    "type": "base64",
                    "media_type": .string(image.mimeType),
                    "data": .string(image.data.base64EncodedString()),
                ]),
            ])
        }
    }

    // MARK: - Response decoding

    private func handle(
        _ event: ServerSentEvent,
        assembler: inout ToolCallAssembler,
        continuation: AsyncThrowingStream<AIStreamEvent, any Error>.Continuation
    ) throws {
        guard let json = try? JSONValue.decode(from: event.data) else { return }
        let type = event.event ?? json["type"]?.stringValue

        switch type {
        case "content_block_start":
            guard let index = json["index"]?.intValue,
                  let block = json["content_block"] else { return }
            if block["type"]?.stringValue == "tool_use",
               let id = block["id"]?.stringValue,
               let name = block["name"]?.stringValue {
                assembler.begin(index: index, id: id, name: name)
            }

        case "content_block_delta":
            guard let delta = json["delta"] else { return }
            switch delta["type"]?.stringValue {
            case "text_delta":
                if let text = delta["text"]?.stringValue, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                }
            case "input_json_delta":
                if let index = json["index"]?.intValue,
                   let fragment = delta["partial_json"]?.stringValue {
                    assembler.append(index: index, fragment: fragment)
                }
            default:
                break
            }

        case "content_block_stop":
            if let index = json["index"]?.intValue,
               let call = try assembler.finish(index: index) {
                continuation.yield(.toolCall(call))
            }

        case "message_delta":
            if let usage = json["usage"], let output = usage["output_tokens"]?.intValue {
                continuation.yield(.usage(AIUsage(inputTokens: nil, outputTokens: output)))
            }
            if let reason = json["delta"]?["stop_reason"]?.stringValue {
                continuation.yield(.finished(Self.stopReason(reason)))
            }

        case "message_start":
            if let usage = json["message"]?["usage"], let input = usage["input_tokens"]?.intValue {
                continuation.yield(.usage(AIUsage(inputTokens: input, outputTokens: nil)))
            }

        case "error":
            let message = json["error"]?["message"]?.stringValue
            throw AppError.providerUnavailable(status: 200, detail: message)

        default:
            break
        }
    }

    static func stopReason(_ raw: String) -> AIStopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "max_tokens": return .maxTokens
        case "tool_use": return .toolUse
        case "stop_sequence": return .stopSequence
        default: return .other
        }
    }
}

/// Reassembles tool calls whose JSON arguments arrive in fragments.
///
/// Shared shape across providers: begin with an id and name, accumulate a JSON
/// string, then parse once the block closes.
struct ToolCallAssembler {
    private struct Pending {
        let id: String
        let name: String
        var json: String
    }

    private var pending: [Int: Pending] = [:]

    mutating func begin(index: Int, id: String, name: String) {
        pending[index] = Pending(id: id, name: name, json: "")
    }

    mutating func append(index: Int, fragment: String) {
        pending[index]?.json += fragment
    }

    /// Returns the completed call, or `nil` if `index` was a text block.
    mutating func finish(index: Int) throws -> AIToolCall? {
        guard let entry = pending.removeValue(forKey: index) else { return nil }
        let arguments: JSONValue
        if entry.json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments = .object([:])
        } else {
            do {
                arguments = try JSONValue.decode(from: entry.json)
            } catch {
                throw AppError.toolArgumentsInvalid(
                    tool: entry.name,
                    detail: "the arguments were not valid JSON"
                )
            }
        }
        return AIToolCall(id: entry.id, name: entry.name, arguments: arguments)
    }

    /// Anything still open when the stream ends (a truncated response).
    mutating func drain() throws -> [AIToolCall] {
        let indices = pending.keys.sorted()
        var calls: [AIToolCall] = []
        for index in indices {
            if let call = try finish(index: index) { calls.append(call) }
        }
        return calls
    }
}
