import Foundation

/// Runs one assistant turn end to end: build the prompt, stream the reply, run
/// any tools the model asks for (confirming the mutating ones), feed the results
/// back, and repeat until the model stops asking.
///
/// Everything it needs is injected, so a test can drive a complete turn —
/// including a tool round-trip — with no network, no AppKit and no clock.
public struct ChatEngine: Sendable {
    public enum Update: Sendable, Equatable {
        case activity(AssistantActivity)
        case textDelta(String)
        case toolInvocation(ToolInvocationRecord)
        case citations([WebCitation])
        /// Reports, after the fact, exactly what screen data left the Mac.
        case screenContextSent(image: Bool, text: Bool)
        case usage(AIUsage)
        case finished
        case failed(AppError)
    }

    public struct Request: Sendable {
        public let conversation: Conversation
        public let screenContext: ScreenContext?
        public let settings: AppSettings
        public let toolContext: ToolContext

        public init(
            conversation: Conversation,
            screenContext: ScreenContext?,
            settings: AppSettings,
            toolContext: ToolContext
        ) {
            self.conversation = conversation
            self.screenContext = screenContext
            self.settings = settings
            self.toolContext = toolContext
        }
    }

    /// Cap on model→tool→model round trips in a single turn. Without it a
    /// confused model can bounce between tools indefinitely on the user's dime.
    public static let maxToolRounds = 4

    private let provider: any ChatModelProviding
    private let runner: ToolRunner
    private let promptBuilder: PromptBuilder
    private let recency: RecencyHeuristic
    private let now: @Sendable () -> Date

    public init(
        provider: any ChatModelProviding,
        runner: ToolRunner,
        promptBuilder: PromptBuilder = PromptBuilder(),
        recency: RecencyHeuristic = RecencyHeuristic(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.runner = runner
        self.promptBuilder = promptBuilder
        self.recency = recency
        self.now = now
    }

    public func run(_ request: Request) -> AsyncStream<Update> {
        AsyncStream { continuation in
            let task = Task {
                await execute(request, emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ request: Request, emit: @Sendable (Update) -> Void) async {
        let settings = request.settings
        let modelID = settings.chatModelID
        let supportsVision = provider.model(withID: modelID)?.supportsVision ?? false
        let lastUserText = request.conversation.messages.last { $0.role == .user }?.text ?? ""
        let needsFresh = settings.webAccessEnabled && recency.likelyNeedsFreshInformation(lastUserText)

        // The model is only offered tools it can actually use.
        let availableTools = runner.specifications.filter { spec in
            if spec.name == WebSearchTool().name { return settings.webAccessEnabled }
            return true
        }
        let supportsTools = provider.model(withID: modelID)?.supportsTools ?? false
        let offeredTools = supportsTools ? availableTools : []

        var pendingToolTurns: [AITurn] = []
        var round = 0

        while true {
            round += 1
            if Task.isCancelled {
                emit(.failed(.cancelled))
                return
            }

            let prompt = promptBuilder.build(PromptBuilder.Input(
                conversation: request.conversation,
                screenContext: request.screenContext,
                settings: settings,
                modelSupportsVision: supportsVision,
                toolNames: offeredTools.map(\.name),
                webAccessEnabled: settings.webAccessEnabled,
                likelyNeedsFreshInformation: needsFresh,
                now: now(),
                pendingToolTurns: pendingToolTurns
            ))

            if round == 1 {
                if request.screenContext != nil {
                    emit(.screenContextSent(
                        image: prompt.didAttachScreenImage,
                        text: prompt.didAttachScreenText
                    ))
                }
                // Refuse to silently drop a capture the user approved.
                if let context = request.screenContext,
                   !prompt.didAttachScreenImage,
                   !prompt.didAttachScreenText {
                    if !settings.mayShareScreenWithProvider {
                        emit(.failed(.screenSharingWithProviderDisabled))
                    } else if !supportsVision && (context.extractedText ?? "").isEmpty {
                        emit(.failed(.modelUnavailable(model: modelID)))
                    } else {
                        emit(.failed(.screenCaptureFailed(detail: "the capture could not be attached")))
                    }
                    return
                }
                if let context = request.screenContext, context.byteCount > settings.maxImageBytes {
                    emit(.failed(.imageTooLarge(bytes: context.byteCount, limit: settings.maxImageBytes)))
                    return
                }
            }

            emit(.activity(.thinking))

            var assistantText = ""
            var toolCalls: [AIToolCall] = []
            var sawText = false

            let aiRequest = AIChatRequest(
                model: modelID,
                system: prompt.system,
                turns: prompt.turns,
                tools: offeredTools,
                maxOutputTokens: settings.maxOutputTokens,
                temperature: settings.temperature,
                stream: true
            )

            do {
                for try await event in provider.streamChat(aiRequest) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        if !sawText {
                            sawText = true
                            emit(.activity(.streaming))
                        }
                        assistantText += delta
                        emit(.textDelta(delta))
                    case .toolCall(let call):
                        toolCalls.append(call)
                    case .usage(let usage):
                        emit(.usage(usage))
                    case .finished:
                        break
                    }
                }
            } catch {
                emit(.failed(AppError.wrapping(error)))
                return
            }

            guard !toolCalls.isEmpty else {
                emit(.finished)
                return
            }

            guard round <= Self.maxToolRounds else {
                // Stop rather than loop. The text so far has already streamed.
                emit(.toolInvocation(ToolInvocationRecord(
                    toolName: "tool loop",
                    summary: "Stopped after \(Self.maxToolRounds) rounds of actions",
                    outcome: .failed,
                    detail: "Ask again with a narrower request.",
                    startedAt: now()
                )))
                emit(.finished)
                return
            }

            pendingToolTurns.append(.assistantToolCalls(
                text: assistantText.isEmpty ? nil : assistantText,
                calls: toolCalls
            ))

            var results: [AIToolResult] = []
            for call in toolCalls {
                if Task.isCancelled {
                    emit(.failed(.cancelled))
                    return
                }
                emit(.activity(activity(for: call)))
                let outcome = await runner.run(call, context: request.toolContext)
                emit(.toolInvocation(outcome.record))
                if !outcome.citations.isEmpty {
                    emit(.citations(outcome.citations))
                }
                results.append(outcome.result)
            }
            pendingToolTurns.append(.toolResults(results))
        }
    }

    private func activity(for call: AIToolCall) -> AssistantActivity {
        if call.name == WebSearchTool().name {
            return .searchingWeb(query: call.arguments["query"]?.stringValue)
        }
        if let tool = runner.tool(named: call.name), tool.sideEffect.requiresConfirmation {
            return .awaitingToolConfirmation(name: call.name)
        }
        return .runningTool(name: call.name)
    }
}
