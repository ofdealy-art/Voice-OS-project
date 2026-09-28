import Foundation

/// A pending request for the user's approval.
public struct ToolConfirmationRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let toolName: String
    /// What the user is being asked, built from the real arguments.
    public let prompt: String
    /// The verb from `ToolSideEffect.mutating`, used for the confirm button.
    public let actionVerb: String

    public init(id: UUID = UUID(), toolName: String, prompt: String, actionVerb: String) {
        self.id = id
        self.toolName = toolName
        self.prompt = prompt
        self.actionVerb = actionVerb
    }
}

/// Asks the user to approve a mutating tool.
///
/// Implemented by the UI layer. `ToolRunner` will not run a mutating tool
/// without a `true` from here, and a runner constructed without a confirmer
/// refuses every mutating tool rather than defaulting to "allow".
public protocol ToolConfirming: Sendable {
    func confirm(_ request: ToolConfirmationRequest) async -> Bool
}

/// Always declines. The safe default, used in tests and in any code path that
/// forgot to wire up a real confirmer.
public struct DenyingToolConfirmer: ToolConfirming {
    public init() {}
    public func confirm(_ request: ToolConfirmationRequest) async -> Bool { false }
}

public struct AlwaysAllowToolConfirmer: ToolConfirming {
    public init() {}
    public func confirm(_ request: ToolConfirmationRequest) async -> Bool { true }
}

/// Resolves and runs tools, enforcing confirmation for anything that mutates.
public struct ToolRunner: Sendable {
    public struct Outcome: Sendable, Equatable {
        public let result: AIToolResult
        public let record: ToolInvocationRecord
        public let citations: [WebCitation]

        public init(result: AIToolResult, record: ToolInvocationRecord, citations: [WebCitation]) {
            self.result = result
            self.record = record
            self.citations = citations
        }
    }

    private let tools: [String: any AssistantTool]
    private let confirmer: any ToolConfirming
    private let now: @Sendable () -> Date

    public init(
        tools: [any AssistantTool],
        confirmer: any ToolConfirming = DenyingToolConfirmer(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.confirmer = confirmer
        self.now = now
    }

    public var specifications: [AIToolSpec] {
        tools.values
            .sorted { $0.name < $1.name }
            .map(\.specification)
    }

    public func tool(named name: String) -> (any AssistantTool)? { tools[name] }

    /// Runs one tool call. Never throws: every failure comes back as an
    /// `AIToolResult` marked `isError` so the model can recover in-conversation
    /// instead of the turn dying.
    public func run(_ call: AIToolCall, context: ToolContext) async -> Outcome {
        let startedAt = now()

        guard let tool = tools[call.name] else {
            let error = AppError.toolNotFound(name: call.name)
            return failure(call: call, error: error, summary: "Unknown action \"\(call.name)\"", startedAt: startedAt)
        }

        if case .mutating(let verb) = tool.sideEffect {
            let request = ToolConfirmationRequest(
                toolName: tool.name,
                prompt: tool.confirmationPrompt(arguments: call.arguments),
                actionVerb: verb
            )
            let approved = await confirmer.confirm(request)
            guard approved else {
                let record = ToolInvocationRecord(
                    toolName: tool.name,
                    summary: "You declined: \(verb)",
                    outcome: .declinedByUser,
                    startedAt: startedAt
                )
                return Outcome(
                    result: AIToolResult(
                        callID: call.id,
                        name: call.name,
                        content: "The user declined this action. Do not try it again unless they ask. Continue without it.",
                        isError: true
                    ),
                    record: record,
                    citations: []
                )
            }
        }

        do {
            let output = try await tool.execute(arguments: call.arguments, context: context)
            let record = ToolInvocationRecord(
                toolName: tool.name,
                summary: output.userVisibleSummary,
                outcome: .succeeded,
                startedAt: startedAt
            )
            return Outcome(
                result: AIToolResult(callID: call.id, name: call.name, content: output.content),
                record: record,
                citations: output.citations
            )
        } catch {
            return failure(
                call: call,
                error: AppError.wrapping(error),
                summary: nil,
                startedAt: startedAt
            )
        }
    }

    private func failure(
        call: AIToolCall,
        error: AppError,
        summary: String?,
        startedAt: Date
    ) -> Outcome {
        let message = error.errorDescription ?? "The action failed."
        let record = ToolInvocationRecord(
            toolName: call.name,
            summary: summary ?? message,
            outcome: .failed,
            detail: error.recoverySuggestion,
            startedAt: startedAt
        )
        return Outcome(
            result: AIToolResult(
                callID: call.id,
                name: call.name,
                content: "The action failed: \(message) Tell the user plainly and continue without it.",
                isError: true
            ),
            record: record,
            citations: []
        )
    }

    // MARK: - Shipping configuration

    /// Every tool the app ships with. `extra` lets `ScreenMateKit` add tools that
    /// need macOS frameworks (screen capture) without Core knowing about them.
    public static func standardTools(extra: [any AssistantTool] = []) -> [any AssistantTool] {
        [
            CurrentDateTimeTool(),
            WebSearchTool(),
            MakeChecklistTool(),
            CopyToClipboardTool(),
            OpenURLTool(),
            CreateNoteTool(),
        ] + extra
    }
}
