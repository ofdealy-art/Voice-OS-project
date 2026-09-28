import XCTest
@testable import ScreenMateCore

final class PromptBuilderTests: XCTestCase {
    private let builder = PromptBuilder()

    private func input(
        screenContext: ScreenContext? = nil,
        settings: AppSettings = AppSettings(),
        modelSupportsVision: Bool = true,
        conversation: Conversation = .fixture(),
        webAccessEnabled: Bool = false,
        needsFresh: Bool = false,
        toolNames: [String] = ["web_search", "current_datetime"]
    ) -> PromptBuilder.Input {
        PromptBuilder.Input(
            conversation: conversation,
            screenContext: screenContext,
            settings: settings,
            modelSupportsVision: modelSupportsVision,
            toolNames: toolNames,
            webAccessEnabled: webAccessEnabled,
            likelyNeedsFreshInformation: needsFresh,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    // MARK: - The privacy rule

    func testScreenshotIsNotAttachedWhenScreenAwarenessIsOff() {
        var settings = AppSettings()
        settings.screenAwarenessEnabled = false
        settings.sendScreenContentToProvider = true

        let output = builder.build(input(screenContext: .fixture(), settings: settings))
        XCTAssertFalse(output.didAttachScreenImage)
        XCTAssertFalse(output.didAttachScreenText)
        XCTAssertFalse(containsImage(output.turns))
    }

    func testScreenshotIsNotAttachedWhenProviderSharingIsOff() {
        var settings = AppSettings()
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = false

        let output = builder.build(input(screenContext: .fixture(), settings: settings))
        XCTAssertFalse(output.didAttachScreenImage)
        XCTAssertFalse(containsImage(output.turns))
    }

    func testScreenshotIsAttachedOnlyWhenBothSwitchesAreOn() {
        let output = builder.build(input(screenContext: .fixture(), settings: sharingEnabled()))
        XCTAssertTrue(output.didAttachScreenImage)
        XCTAssertTrue(containsImage(output.turns))
    }

    func testNoScreenshotIsAttachedWhenNoneWasCaptured() {
        let output = builder.build(input(screenContext: nil, settings: sharingEnabled()))
        XCTAssertFalse(output.didAttachScreenImage)
        XCTAssertFalse(containsImage(output.turns))
    }

    func testOCRTextIsSentWhenTheModelHasNoVision() {
        let output = builder.build(input(
            screenContext: .fixture(extractedText: "error TS2345 on line 12"),
            settings: sharingEnabled(),
            modelSupportsVision: false
        ))
        XCTAssertFalse(output.didAttachScreenImage)
        XCTAssertTrue(output.didAttachScreenText)
        XCTAssertTrue(promptText(output.turns).contains("error TS2345 on line 12"))
    }

    func testTextOnlyModelWithNoOCRTextAttachesNothing() {
        let output = builder.build(input(
            screenContext: .fixture(extractedText: nil),
            settings: sharingEnabled(),
            modelSupportsVision: false
        ))
        XCTAssertFalse(output.didAttachScreenImage)
        XCTAssertFalse(output.didAttachScreenText)
    }

    func testRedactionIsDisclosedToTheModel() {
        let context = ScreenContext.fixture(
            extractedText: "key = [redacted]",
            findings: [RedactionFinding(category: .apiKey, count: 1)]
        )
        let output = builder.build(input(screenContext: context, settings: sharingEnabled()))
        let text = promptText(output.turns)
        XCTAssertTrue(text.contains("Removed 1 API key before sending."))
        XCTAssertTrue(text.contains("do not guess it"))
    }

    // MARK: - Transcript shape

    func testOnlyTheCurrentUserTurnCarriesTheImage() {
        var conversation = Conversation.fixture(userText: "first question")
        conversation.messages.append(ChatMessage(role: .assistant, text: "first answer", source: .model))
        conversation.messages.append(ChatMessage(role: .user, text: "now look at this", source: .typed))

        let output = builder.build(input(
            screenContext: .fixture(),
            settings: sharingEnabled(),
            conversation: conversation
        ))

        let imageTurns = output.turns.filter { turn in
            if case .message(let message) = turn { return message.containsImage }
            return false
        }
        XCTAssertEqual(imageTurns.count, 1)
        // …and it is the last turn.
        if case .message(let message) = output.turns.last {
            XCTAssertTrue(message.containsImage)
            XCTAssertEqual(message.role, .user)
        } else {
            XCTFail("last turn should be the user's message")
        }
    }

    func testFailedAndEmptyMessagesAreNotSentBack() {
        var conversation = Conversation.fixture(userText: "hello")
        conversation.messages.append(ChatMessage(
            role: .assistant,
            text: "",
            source: .model,
            failure: MessageFailure(.networkUnavailable)
        ))
        conversation.messages.append(ChatMessage(role: .user, text: "try again", source: .typed))

        let output = builder.build(input(conversation: conversation))
        XCTAssertFalse(promptText(output.turns).contains("No network connection"))
    }

    func testHistoryIsTrimmedToTheLimit() {
        var conversation = Conversation.fixture(userText: "q0")
        for index in 1...40 {
            conversation.messages.append(ChatMessage(
                role: index.isMultiple(of: 2) ? .assistant : .user,
                text: "message \(index)",
                source: .typed
            ))
        }
        let trimmed = PromptBuilder(historyLimit: 6).build(input(conversation: conversation))
        XCTAssertEqual(trimmed.turns.count, 6)
        XCTAssertFalse(promptText(trimmed.turns).contains("message 1"))
        XCTAssertTrue(promptText(trimmed.turns).contains("message 40"))
    }

    func testEmptyMessageWithACaptureGetsAPlaceholderPrompt() {
        // What the app actually produces when the user captures and presses send
        // without typing: empty text, but a real attachment.
        let context = ScreenContext.fixture()
        var conversation = Conversation.fixture(userText: "")
        conversation.messages[0].text = ""
        conversation.messages[0].attachments = [context.attachment(includeExtractedText: false)]

        let output = builder.build(input(
            screenContext: context,
            settings: sharingEnabled(),
            conversation: conversation
        ))
        XCTAssertTrue(promptText(output.turns).contains("no message"))
    }

    func testAnEmptyPlaceholderMessageIsNotSent() {
        // The blank streaming bubble the UI adds before the first token must never
        // be echoed back to the provider.
        var conversation = Conversation.fixture(userText: "hello")
        conversation.messages.append(ChatMessage(role: .assistant, text: "", source: .model, isStreaming: true))

        let output = builder.build(input(conversation: conversation))
        XCTAssertEqual(output.turns.count, 1)
    }

    // MARK: - System prompt

    func testSystemPromptStatesTheLocalDateAndTime() {
        let output = builder.build(input())
        XCTAssertTrue(output.system.contains("2023"))
        XCTAssertTrue(output.system.contains("GMT"))
    }

    func testSystemPromptSaysWebAccessIsOffWhenItIs() {
        let output = builder.build(input(webAccessEnabled: false))
        XCTAssertTrue(output.system.contains("Web access is switched off"))
        XCTAssertFalse(output.system.contains("prefer searching"))
    }

    func testSystemPromptNudgesSearchForTimeSensitiveQuestions() {
        let output = builder.build(input(webAccessEnabled: true, needsFresh: true))
        XCTAssertTrue(output.system.contains("prefer searching over answering from memory"))
    }

    func testSystemPromptExplainsThatMutatingActionsAreConfirmed() {
        let output = builder.build(input(toolNames: ["copy_to_clipboard"]))
        XCTAssertTrue(output.system.contains("approval before it runs"))
    }

    func testSystemPromptAsksForSpeakableTextWhenTTSIsOn() {
        var settings = AppSettings()
        settings.speakResponses = true
        XCTAssertTrue(builder.build(input(settings: settings)).system.contains("read aloud"))

        settings.speakResponses = false
        XCTAssertFalse(builder.build(input(settings: settings)).system.contains("read aloud"))
    }

    func testSystemPromptTellsTheModelItCannotCaptureOnItsOwn() {
        var settings = AppSettings()
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = true
        let output = builder.build(input(screenContext: nil, settings: settings))
        XCTAssertTrue(output.system.contains("you cannot take one yourself"))
    }

    // MARK: - Helpers

    private func sharingEnabled() -> AppSettings {
        var settings = AppSettings()
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = true
        return settings
    }

    private func containsImage(_ turns: [AITurn]) -> Bool {
        turns.contains { turn in
            if case .message(let message) = turn { return message.containsImage }
            return false
        }
    }

    private func promptText(_ turns: [AITurn]) -> String {
        turns.map { turn -> String in
            guard case .message(let message) = turn else { return "" }
            return message.parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

final class RecencyHeuristicTests: XCTestCase {
    private let heuristic = RecencyHeuristic()

    func testDetectsExplicitRecencyCues() {
        for phrase in [
            "what's the latest on this",
            "who won yesterday",
            "current price of the stock",
            "any news about the outage",
        ] {
            XCTAssertTrue(heuristic.likelyNeedsFreshInformation(phrase), phrase)
        }
    }

    func testDetectsTheCurrentYear() {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        XCTAssertTrue(heuristic.likelyNeedsFreshInformation("best practices \(year)"))
    }

    func testIgnoresTimelessQuestions() {
        for phrase in [
            "explain this error message",
            "rewrite this paragraph professionally",
            "what does this function do",
        ] {
            XCTAssertFalse(heuristic.likelyNeedsFreshInformation(phrase), phrase)
        }
    }
}
