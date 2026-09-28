import Foundation

public struct AIModel: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let supportsVision: Bool
    public let supportsStreaming: Bool
    public let supportsTools: Bool

    public init(
        id: String,
        displayName: String,
        supportsVision: Bool,
        supportsStreaming: Bool = true,
        supportsTools: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsVision = supportsVision
        self.supportsStreaming = supportsStreaming
        self.supportsTools = supportsTools
    }
}

public struct AIImagePayload: Sendable, Equatable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public enum AIContentPart: Sendable, Equatable {
    case text(String)
    case image(AIImagePayload)
}

public struct AIRequestMessage: Sendable, Equatable {
    public let role: MessageRole
    public let parts: [AIContentPart]

    public init(role: MessageRole, parts: [AIContentPart]) {
        self.role = role
        self.parts = parts
    }

    public static func text(_ role: MessageRole, _ text: String) -> AIRequestMessage {
        AIRequestMessage(role: role, parts: [.text(text)])
    }

    public var containsImage: Bool {
        parts.contains { if case .image = $0 { return true } else { return false } }
    }
}

/// A tool offered to the model, described with JSON Schema.
public struct AIToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct AIToolCall: Sendable, Equatable, Identifiable {
    /// Provider-assigned id, echoed back with the result.
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The result of a tool call, fed back to the model on the next turn.
public struct AIToolResult: Sendable, Equatable {
    public let callID: String
    public let name: String
    public let content: String
    public let isError: Bool

    public init(callID: String, name: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.content = content
        self.isError = isError
    }
}

/// One entry in the running transcript sent to the provider. Tool traffic is
/// modelled separately from plain messages because providers encode it
/// differently (Anthropic uses content blocks, OpenAI uses dedicated roles).
public enum AITurn: Sendable, Equatable {
    case message(AIRequestMessage)
    case assistantToolCalls(text: String?, calls: [AIToolCall])
    case toolResults([AIToolResult])
}

public struct AIChatRequest: Sendable {
    public let model: String
    public let system: String
    public let turns: [AITurn]
    public let tools: [AIToolSpec]
    public let maxOutputTokens: Int
    public let temperature: Double
    public let stream: Bool

    public init(
        model: String,
        system: String,
        turns: [AITurn],
        tools: [AIToolSpec] = [],
        maxOutputTokens: Int = 2048,
        temperature: Double = 0.7,
        stream: Bool = true
    ) {
        self.model = model
        self.system = system
        self.turns = turns
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.stream = stream
    }
}

public struct AIUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(inputTokens: Int?, outputTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum AIStopReason: String, Sendable {
    case endTurn
    case maxTokens
    case toolUse
    case stopSequence
    case other
}

public enum AIStreamEvent: Sendable, Equatable {
    /// Incremental assistant text.
    case textDelta(String)
    /// The model wants a tool run. Emitted once the arguments are complete.
    case toolCall(AIToolCall)
    case usage(AIUsage)
    case finished(AIStopReason)
}

/// A chat/vision model backend.
///
/// One protocol covers both because every current vision model is also a chat
/// model; `AIModel.supportsVision` reports per-model capability so the app can
/// refuse to attach a screenshot to a text-only model instead of failing at the
/// network layer.
public protocol ChatModelProviding: Sendable {
    var id: String { get }
    var displayName: String { get }
    var models: [AIModel] { get }
    var requiresAPIKey: Bool { get }
    /// Where the user gets a key. Linked from Settings.
    var apiKeyHelpURL: URL? { get }

    /// Streams a reply. Implementations must translate transport and HTTP
    /// failures into `AppError` and must finish the stream on cancellation.
    func streamChat(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, any Error>
}

public extension ChatModelProviding {
    var apiKeyHelpURL: URL? { nil }

    func model(withID id: String) -> AIModel? {
        models.first { $0.id == id }
    }

    /// Collects a full reply. Convenience for tests and non-streaming callers.
    func completeChat(_ request: AIChatRequest) async throws -> (text: String, toolCalls: [AIToolCall]) {
        var text = ""
        var calls: [AIToolCall] = []
        for try await event in streamChat(request) {
            switch event {
            case .textDelta(let delta): text += delta
            case .toolCall(let call): calls.append(call)
            case .usage, .finished: break
            }
        }
        return (text, calls)
    }
}
