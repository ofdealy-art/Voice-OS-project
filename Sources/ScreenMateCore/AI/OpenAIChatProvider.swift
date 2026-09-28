import Foundation

/// OpenAI Chat Completions provider (streaming, vision, tool calls).
///
/// Also works with any server that implements the same wire format — set a
/// custom `baseURL` (e.g. an Ollama or LM Studio endpoint) to run locally.
public struct OpenAIChatProvider: ChatModelProviding {
    public static let providerID = "openai"

    public let id: String
    public let displayName: String
    public let requiresAPIKey: Bool
    public var apiKeyHelpURL: URL? { URL(string: "https://platform.openai.com/api-keys") }
    public let models: [AIModel]

    private let apiKey: String
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let mapper: ProviderErrorMapper

    public static let defaultModels: [AIModel] = [
        AIModel(id: "gpt-4o", displayName: "GPT-4o", supportsVision: true),
        AIModel(id: "gpt-4o-mini", displayName: "GPT-4o mini", supportsVision: true),
        AIModel(id: "gpt-4.1", displayName: "GPT-4.1", supportsVision: true),
    ]

    public init(
        apiKey: String,
        transport: any HTTPTransport,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        id: String = OpenAIChatProvider.providerID,
        displayName: String = "OpenAI",
        requiresAPIKey: Bool = true,
        models: [AIModel] = OpenAIChatProvider.defaultModels
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
        self.id = id
        self.displayName = displayName
        self.requiresAPIKey = requiresAPIKey
        self.models = models
        self.mapper = ProviderErrorMapper(providerDisplayName: displayName)
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
        if requiresAPIKey && apiKey.isEmpty {
            throw AppError.missingAPIKey(provider: displayName)
        }

        let urlRequest = try makeRequest(request)
        let (lines, metadata) = try await transport.stream(urlRequest)

        guard metadata.isSuccess else {
            var body = ""
            for try await line in lines { body += line }
            throw mapper.error(for: metadata, body: body, requestedModel: request.model)
        }

        var parser = ServerSentEventParser()
        var assembler = ToolCallAssembler()
        var sawFinish = false

        func process(_ event: ServerSentEvent) throws {
            if event.isDoneSentinel { return }
            guard let json = try? JSONValue.decode(from: event.data) else { return }

            if let message = json["error"]?["message"]?.stringValue {
                throw AppError.providerUnavailable(status: 200, detail: message)
            }
            guard let choice = json["choices"]?.arrayValue?.first else {
                if let usage = json["usage"] {
                    continuation.yield(.usage(AIUsage(
                        inputTokens: usage["prompt_tokens"]?.intValue,
                        outputTokens: usage["completion_tokens"]?.intValue
                    )))
                }
                return
            }

            if let delta = choice["delta"] {
                if let content = delta["content"]?.stringValue, !content.isEmpty {
                    continuation.yield(.textDelta(content))
                }
                if let calls = delta["tool_calls"]?.arrayValue {
                    for call in calls {
                        let index = call["index"]?.intValue ?? 0
                        if let id = call["id"]?.stringValue,
                           let name = call["function"]?["name"]?.stringValue {
                            assembler.begin(index: index, id: id, name: name)
                        }
                        if let fragment = call["function"]?["arguments"]?.stringValue, !fragment.isEmpty {
                            assembler.append(index: index, fragment: fragment)
                        }
                    }
                }
            }

            if let reason = choice["finish_reason"]?.stringValue {
                // OpenAI closes all tool-call blocks at once, at finish time.
                for call in try assembler.drain() {
                    continuation.yield(.toolCall(call))
                }
                continuation.yield(.finished(Self.stopReason(reason)))
                sawFinish = true
            }
        }

        for try await line in lines {
            try Task.checkCancellation()
            guard let event = parser.consume(line: line) else { continue }
            try process(event)
        }
        if let event = parser.flush() { try process(event) }

        if !sawFinish {
            // Truncated stream: still surface whatever tool calls we assembled.
            for call in try assembler.drain() {
                continuation.yield(.toolCall(call))
            }
        }
    }

    // MARK: - Request encoding

    private func makeRequest(_ request: AIChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [JSONValue] = []
        if !request.system.isEmpty {
            messages.append(.object(["role": "system", "content": .string(request.system)]))
        }
        messages.append(contentsOf: Self.encodeTurns(request.turns))

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "max_tokens": .number(Double(request.maxOutputTokens)),
            "temperature": .number(request.temperature),
            "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": "function",
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters,
                    ]),
                ])
            })
        }

        urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return urlRequest
    }

    static func encodeTurns(_ turns: [AITurn]) -> [JSONValue] {
        var messages: [JSONValue] = []
        for turn in turns {
            switch turn {
            case .message(let message):
                messages.append(.object([
                    "role": .string(message.role.rawValue),
                    "content": encodeContent(message.parts),
                ]))

            case .assistantToolCalls(let text, let calls):
                var entry: [String: JSONValue] = ["role": "assistant"]
                entry["content"] = text.map { JSONValue.string($0) } ?? .null
                entry["tool_calls"] = .array(calls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": "function",
                        "function": .object([
                            "name": .string(call.name),
                            // OpenAI expects arguments as a JSON *string*.
                            "arguments": .string((try? call.arguments.encodedString()) ?? "{}"),
                        ]),
                    ])
                })
                messages.append(.object(entry))

            case .toolResults(let results):
                for result in results {
                    messages.append(.object([
                        "role": "tool",
                        "tool_call_id": .string(result.callID),
                        "content": .string(result.content),
                    ]))
                }
            }
        }
        return messages
    }

    private static func encodeContent(_ parts: [AIContentPart]) -> JSONValue {
        // A lone text part is sent as a bare string, which every
        // OpenAI-compatible server accepts, including ones without vision.
        if parts.count == 1, case .text(let text) = parts[0] {
            return .string(text)
        }
        return .array(parts.map { part in
            switch part {
            case .text(let text):
                return .object(["type": "text", "text": .string(text)])
            case .image(let image):
                let dataURL = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
                return .object([
                    "type": "image_url",
                    "image_url": .object(["url": .string(dataURL)]),
                ])
            }
        })
    }

    static func stopReason(_ raw: String) -> AIStopReason {
        switch raw {
        case "stop": return .endTurn
        case "length": return .maxTokens
        case "tool_calls", "function_call": return .toolUse
        default: return .other
        }
    }
}
