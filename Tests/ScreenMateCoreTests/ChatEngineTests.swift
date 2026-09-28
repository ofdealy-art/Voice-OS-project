import XCTest
@testable import ScreenMateCore

final class ChatEngineTests: XCTestCase {
    private func settings(
        model: String = "scripted-1",
        webAccess: Bool = false,
        screenSharing: Bool = false
    ) -> AppSettings {
        var settings = AppSettings()
        settings.chatProviderID = "scripted"
        settings.chatModelID = model
        settings.webAccessEnabled = webAccess
        settings.screenAwarenessEnabled = screenSharing
        settings.sendScreenContentToProvider = screenSharing
        return settings
    }

    private func collect(_ stream: AsyncStream<ChatEngine.Update>) async -> [ChatEngine.Update] {
        var updates: [ChatEngine.Update] = []
        for await update in stream { updates.append(update) }
        return updates
    }

    func testStreamsTextThenFinishes() async {
        let provider = ScriptedChatProvider(rounds: [.init(text: "You are looking at Xcode.")])
        let engine = ChatEngine(provider: provider, runner: ToolRunner(tools: []))

        let updates = await collect(engine.run(.init(
            conversation: .fixture(),
            screenContext: nil,
            settings: settings(),
            toolContext: .testing()
        )))

        XCTAssertTrue(updates.contains(.activity(.thinking)))
        XCTAssertTrue(updates.contains(.activity(.streaming)))
        XCTAssertTrue(updates.contains(.textDelta("You are looking at Xcode.")))
        XCTAssertEqual(updates.last, .finished)
    }

    func testRunsAToolThenFeedsTheResultBackAndAnswers() async {
        let search = StubSearchProvider(results: [
            WebSearchResult(
                title: "Swift 6.2",
                url: URL(string: "https://swift.org/blog")!,
                snippet: "Released today."
            )
        ])
        let provider = ScriptedChatProvider(rounds: [
            .init(toolCalls: [
                AIToolCall(id: "call_1", name: "web_search", arguments: .object(["query": "swift 6.2"]))
            ]),
            .init(text: "Swift 6.2 shipped, according to swift.org."),
        ])
        let engine = ChatEngine(
            provider: provider,
            runner: ToolRunner(tools: [WebSearchTool()], confirmer: AlwaysAllowToolConfirmer())
        )

        let updates = await collect(engine.run(.init(
            conversation: .fixture(userText: "what's the latest swift release"),
            screenContext: nil,
            settings: settings(webAccess: true),
            toolContext: .testing(search: search)
        )))

        XCTAssertEqual(search.queries, ["swift 6.2"])
        XCTAssertTrue(updates.contains(.activity(.searchingWeb(query: "swift 6.2"))))
        XCTAssertTrue(updates.contains(.textDelta("Swift 6.2 shipped, according to swift.org.")))
        XCTAssertEqual(updates.last, .finished)

        // The second request must carry the tool call and its result.
        XCTAssertEqual(provider.receivedRequests.count, 2)
        let secondTurns = provider.receivedRequests[1].turns
        XCTAssertTrue(secondTurns.contains { if case .assistantToolCalls = $0 { return true } else { return false } })
        XCTAssertTrue(secondTurns.contains { if case .toolResults = $0 { return true } else { return false } })

        let citationUpdates = updates.compactMap { update -> [WebCitation]? in
            if case .citations(let citations) = update { return citations }
            return nil
        }
        XCTAssertEqual(citationUpdates.first?.first?.url.absoluteString, "https://swift.org/blog")
    }

    func testDeclinedToolStillLetsTheTurnFinish() async {
        let clipboard = SpyClipboard()
        let provider = ScriptedChatProvider(rounds: [
            .init(toolCalls: [
                AIToolCall(id: "call_1", name: "copy_to_clipboard", arguments: .object(["text": "hi"]))
            ]),
            .init(text: "Understood, I left your clipboard alone."),
        ])
        let engine = ChatEngine(
            provider: provider,
            runner: ToolRunner(tools: [CopyToClipboardTool()], confirmer: StubToolConfirmer(approve: false))
        )

        let updates = await collect(engine.run(.init(
            conversation: .fixture(userText: "copy that for me"),
            screenContext: nil,
            settings: settings(),
            toolContext: .testing(clipboard: clipboard)
        )))

        XCTAssertTrue(clipboard.written.isEmpty)
        XCTAssertTrue(updates.contains(.activity(.awaitingToolConfirmation(name: "copy_to_clipboard"))))
        XCTAssertTrue(updates.contains(.textDelta("Understood, I left your clipboard alone.")))
        XCTAssertEqual(updates.last, .finished)

        let records = updates.compactMap { update -> ToolInvocationRecord? in
            if case .toolInvocation(let record) = update { return record }
            return nil
        }
        XCTAssertEqual(records.first?.outcome, .declinedByUser)
    }

    func testWebSearchToolIsNotOfferedWhenWebAccessIsOff() async {
        let provider = ScriptedChatProvider(rounds: [.init(text: "ok")])
        let engine = ChatEngine(
            provider: provider,
            runner: ToolRunner(tools: ToolRunner.standardTools())
        )
        _ = await collect(engine.run(.init(
            conversation: .fixture(),
            screenContext: nil,
            settings: settings(webAccess: false),
            toolContext: .testing()
        )))
        let offered = provider.receivedRequests[0].tools.map(\.name)
        XCTAssertFalse(offered.contains("web_search"))
        XCTAssertTrue(offered.contains("current_datetime"))
    }

    func testNoToolsAreOfferedToAModelThatCannotUseThem() async {
        let provider = ScriptedChatProvider(rounds: [.init(text: "ok")], supportsTools: false)
        let engine = ChatEngine(provider: provider, runner: ToolRunner(tools: ToolRunner.standardTools()))
        _ = await collect(engine.run(.init(
            conversation: .fixture(),
            screenContext: nil,
            settings: settings(webAccess: true),
            toolContext: .testing()
        )))
        XCTAssertTrue(provider.receivedRequests[0].tools.isEmpty)
    }

    func testReportsExactlyWhatScreenDataWasSent() async {
        let provider = ScriptedChatProvider(rounds: [.init(text: "That is Xcode.")])
        let engine = ChatEngine(provider: provider, runner: ToolRunner(tools: []))

        let updates = await collect(engine.run(.init(
            conversation: .fixture(),
            screenContext: .fixture(),
            settings: settings(screenSharing: true),
            toolContext: .testing()
        )))
        XCTAssertTrue(updates.contains(.screenContextSent(image: true, text: false)))
    }

    func testRefusesToSilentlyDropACaptureWhenSharingIsOff() async {
        let provider = ScriptedChatProvider(rounds: [.init(text: "should not be reached")])
        let engine = ChatEngine(provider: provider, runner: ToolRunner(tools: []))

        let updates = await collect(engine.run(.init(
            conversation: .fixture(),
            screenContext: .fixture(),
            settings: settings(screenSharing: false),
            toolContext: .testing()
        )))
        XCTAssertEqual(updates.last, .failed(.screenSharingWithProviderDisabled))
        XCTAssertTrue(provider.receivedRequests.isEmpty, "nothing may be sent")
    }

    func testOversizedImageIsRejectedBeforeUpload() async {
        var configuration = settings(screenSharing: true)
        configuration.maxImageBytes = 512
        let provider = ScriptedChatProvider(rounds: [.init(text: "should not be reached")])
        let engine = ChatEngine(provider: provider, runner: ToolRunner(tools: []))

        let updates = await collect(engine.run(.init(
            conversation: .fixture(),
            screenContext: .fixture(bytes: 4096),
            settings: configuration,
            toolContext: .testing()
        )))
        XCTAssertEqual(updates.last, .failed(.imageTooLarge(bytes: 4096, limit: 512)))
        XCTAssertTrue(provider.receivedRequests.isEmpty)
    }

    func testProviderFailureIsSurfacedAsAFailedUpdate() async {
        let provider = ScriptedChatProvider(rounds: [.init(error: .rateLimited(retryAfter: 12))])
        let engine = ChatEngine(provider: provider, runner: ToolRunner(tools: []))

        let updates = await collect(engine.run(.init(
            conversation: .fixture(),
            screenContext: nil,
            settings: settings(),
            toolContext: .testing()
        )))
        XCTAssertEqual(updates.last, .failed(.rateLimited(retryAfter: 12)))
    }

    func testToolLoopIsBounded() async {
        // A model that keeps asking for the same tool forever.
        let rounds = (0..<12).map { index in
            ScriptedChatProvider.Round(toolCalls: [
                AIToolCall(id: "call_\(index)", name: "current_datetime", arguments: .object([:]))
            ])
        }
        let provider = ScriptedChatProvider(rounds: rounds)
        let engine = ChatEngine(provider: provider, runner: ToolRunner(tools: [CurrentDateTimeTool()]))

        let updates = await collect(engine.run(.init(
            conversation: .fixture(),
            screenContext: nil,
            settings: settings(),
            toolContext: .testing()
        )))

        XCTAssertEqual(updates.last, .finished)
        XCTAssertLessThanOrEqual(provider.receivedRequests.count, ChatEngine.maxToolRounds + 1)
        let records = updates.compactMap { update -> ToolInvocationRecord? in
            if case .toolInvocation(let record) = update { return record }
            return nil
        }
        XCTAssertTrue(records.contains { $0.toolName == "tool loop" })
    }

    func testDemoProviderProducesAReplyWithNoNetwork() async {
        let provider = DemoChatProvider(chunkDelay: .zero)
        let engine = ChatEngine(provider: provider, runner: ToolRunner(tools: []))
        var configuration = settings()
        configuration.chatModelID = "demo-1"

        let updates = await collect(engine.run(.init(
            conversation: .fixture(userText: "hello there"),
            screenContext: nil,
            settings: configuration,
            toolContext: .testing()
        )))

        let text = updates.compactMap { update -> String? in
            if case .textDelta(let delta) = update { return delta }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("Offline demo provider"))
        XCTAssertEqual(updates.last, .finished)
    }
}
