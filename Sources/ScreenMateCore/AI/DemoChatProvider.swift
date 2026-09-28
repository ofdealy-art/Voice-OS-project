import Foundation

/// A provider that never touches the network.
///
/// Two jobs: it lets someone install ScreenMate and try the whole interface —
/// widget, voice, capture preview, streaming UI — before they have an API key,
/// and it is the fixture the chat tests run against. It is transparently
/// labelled in the UI so its replies are never mistaken for a model's.
public struct DemoChatProvider: ChatModelProviding {
    public static let providerID = "demo"

    public let id = DemoChatProvider.providerID
    public let displayName = "Demo (offline)"
    public let requiresAPIKey = false
    public let models: [AIModel] = [
        AIModel(id: "demo-1", displayName: "Scripted demo", supportsVision: true, supportsTools: false),
    ]

    /// Delay between emitted chunks, so the streaming UI can be seen working.
    private let chunkDelay: Duration
    private let scriptedReply: (@Sendable (AIChatRequest) -> String)?

    public init(
        chunkDelay: Duration = .milliseconds(18),
        scriptedReply: (@Sendable (AIChatRequest) -> String)? = nil
    ) {
        self.chunkDelay = chunkDelay
        self.scriptedReply = scriptedReply
    }

    public func streamChat(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, any Error> {
        let reply = scriptedReply?(request) ?? Self.defaultReply(for: request)
        let delay = chunkDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled {
                        continuation.finish(throwing: AppError.cancelled)
                        return
                    }
                    continuation.yield(.textDelta(String(word) + " "))
                    if delay > .zero {
                        try? await Task.sleep(for: delay)
                    }
                }
                continuation.yield(.usage(AIUsage(inputTokens: nil, outputTokens: nil)))
                continuation.yield(.finished(.endTurn))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func defaultReply(for request: AIChatRequest) -> String {
        let sawImage = request.turns.contains { turn in
            if case .message(let message) = turn { return message.containsImage }
            return false
        }
        if sawImage {
            return """
            This is ScreenMate's offline demo provider, so no model actually looked \
            at your screen. It did receive the screenshot you approved, which means \
            capture, preview and the request pipeline are all working. Add an API \
            key in Settings › Provider to get a real answer.
            """
        }
        let lastUserText: String? = request.turns.reversed().compactMap { turn -> String? in
            guard case .message(let message) = turn, message.role == .user else { return nil }
            return message.parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined(separator: " ")
        }.first

        if let lastUserText, !lastUserText.isEmpty {
            return """
            Offline demo provider here — I can't reason about "\(lastUserText.prefix(80))" \
            without a model behind me. Everything else in the pipeline worked: your \
            message arrived, streaming is live, and text-to-speech will read this out \
            if you have it on. Add an API key in Settings › Provider for real replies.
            """
        }
        return "Offline demo provider. Add an API key in Settings › Provider to talk to a real model."
    }
}
