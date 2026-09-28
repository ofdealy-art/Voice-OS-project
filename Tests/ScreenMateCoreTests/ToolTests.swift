import XCTest
@testable import ScreenMateCore

final class ToolRunnerTests: XCTestCase {
    func testReadOnlyToolRunsWithoutAskingTheUser() async {
        let confirmer = StubToolConfirmer(approve: false)
        let runner = ToolRunner(tools: [CurrentDateTimeTool()], confirmer: confirmer)
        let outcome = await runner.run(
            AIToolCall(id: "1", name: "current_datetime", arguments: .object([:])),
            context: .testing()
        )
        XCTAssertTrue(confirmer.requests.isEmpty)
        XCTAssertEqual(outcome.record.outcome, .succeeded)
        XCTAssertFalse(outcome.result.isError)
    }

    func testMutatingToolIsBlockedWhenTheUserDeclines() async {
        let clipboard = SpyClipboard()
        let confirmer = StubToolConfirmer(approve: false)
        let runner = ToolRunner(tools: [CopyToClipboardTool()], confirmer: confirmer)

        let outcome = await runner.run(
            AIToolCall(id: "1", name: "copy_to_clipboard", arguments: .object(["text": "hello"])),
            context: .testing(clipboard: clipboard)
        )

        XCTAssertEqual(confirmer.requests.count, 1)
        XCTAssertEqual(confirmer.requests[0].toolName, "copy_to_clipboard")
        XCTAssertEqual(confirmer.requests[0].actionVerb, "replace your clipboard contents")
        XCTAssertTrue(clipboard.written.isEmpty, "nothing may be written without approval")
        XCTAssertEqual(outcome.record.outcome, .declinedByUser)
        XCTAssertTrue(outcome.result.isError)
    }

    func testMutatingToolRunsOnceApproved() async {
        let clipboard = SpyClipboard()
        let runner = ToolRunner(tools: [CopyToClipboardTool()], confirmer: StubToolConfirmer(approve: true))

        let outcome = await runner.run(
            AIToolCall(id: "1", name: "copy_to_clipboard", arguments: .object(["text": "hello"])),
            context: .testing(clipboard: clipboard)
        )

        XCTAssertEqual(clipboard.written, ["hello"])
        XCTAssertEqual(outcome.record.outcome, .succeeded)
        XCTAssertEqual(outcome.record.summary, "Copied 5 characters to your clipboard")
    }

    func testDefaultConfirmerDeniesEverythingThatMutates() async {
        let clipboard = SpyClipboard()
        // No confirmer passed: the safe default must be "no".
        let runner = ToolRunner(tools: [CopyToClipboardTool()])
        let outcome = await runner.run(
            AIToolCall(id: "1", name: "copy_to_clipboard", arguments: .object(["text": "x"])),
            context: .testing(clipboard: clipboard)
        )
        XCTAssertTrue(clipboard.written.isEmpty)
        XCTAssertEqual(outcome.record.outcome, .declinedByUser)
    }

    func testEveryShippedToolThatMutatesRequiresConfirmation() {
        for tool in ToolRunner.standardTools() {
            switch tool.name {
            case "copy_to_clipboard", "open_url", "create_note":
                XCTAssertTrue(
                    tool.sideEffect.requiresConfirmation,
                    "\(tool.name) changes something and must be confirmed"
                )
            default:
                XCTAssertFalse(
                    tool.sideEffect.requiresConfirmation,
                    "\(tool.name) is read-only and should not interrupt the user"
                )
            }
        }
    }

    func testUnknownToolFailsWithoutCrashing() async {
        let runner = ToolRunner(tools: [CurrentDateTimeTool()])
        let outcome = await runner.run(
            AIToolCall(id: "1", name: "delete_everything", arguments: .object([:])),
            context: .testing()
        )
        XCTAssertEqual(outcome.record.outcome, .failed)
        XCTAssertTrue(outcome.result.isError)
        XCTAssertEqual(outcome.record.summary, "Unknown action \"delete_everything\"")
    }

    func testToolFailureBecomesAModelReadableErrorRatherThanAThrow() async {
        let clipboard = SpyClipboard()
        clipboard.errorToThrow = AppError.storageFailure(detail: "pasteboard busy")
        let runner = ToolRunner(tools: [CopyToClipboardTool()], confirmer: AlwaysAllowToolConfirmer())
        let outcome = await runner.run(
            AIToolCall(id: "1", name: "copy_to_clipboard", arguments: .object(["text": "x"])),
            context: .testing(clipboard: clipboard)
        )
        XCTAssertEqual(outcome.record.outcome, .failed)
        XCTAssertTrue(outcome.result.content.contains("failed"))
    }

    func testSpecificationsAreStablyOrdered() {
        let runner = ToolRunner(tools: ToolRunner.standardTools())
        let names = runner.specifications.map(\.name)
        XCTAssertEqual(names, names.sorted())
    }
}

final class BuiltInToolTests: XCTestCase {
    func testOpenURLRefusesNonWebSchemes() async {
        let opener = SpyURLOpener()
        let tool = OpenURLTool()
        do {
            _ = try await tool.execute(
                arguments: .object(["url": "file:///etc/passwd"]),
                context: .testing(urlOpener: opener)
            )
            XCTFail("file URLs must be refused")
        } catch let error as AppError {
            XCTAssertEqual(
                error,
                .toolArgumentsInvalid(tool: "open_url", detail: "only http and https addresses can be opened")
            )
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testOpenURLAcceptsHTTPS() async throws {
        let opener = SpyURLOpener()
        let output = try await OpenURLTool().execute(
            arguments: .object(["url": "https://example.com/docs"]),
            context: .testing(urlOpener: opener)
        )
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://example.com/docs"])
        XCTAssertEqual(output.userVisibleSummary, "Opened example.com")
    }

    func testOpenURLConfirmationShowsTheActualAddress() {
        let prompt = OpenURLTool().confirmationPrompt(
            arguments: .object(["url": "https://example.com", "reason": "the release notes"])
        )
        XCTAssertTrue(prompt.contains("https://example.com"))
        XCTAssertTrue(prompt.contains("the release notes"))
    }

    func testWebSearchSurfacesResultsAndCitations() async throws {
        let search = StubSearchProvider(results: [
            WebSearchResult(
                title: "Swift 6.2 released",
                url: URL(string: "https://swift.org/blog/swift-6-2")!,
                snippet: "Swift 6.2 is now available."
            )
        ])
        let output = try await WebSearchTool().execute(
            arguments: .object(["query": "swift 6.2 release"]),
            context: .testing(search: search)
        )
        XCTAssertEqual(search.queries, ["swift 6.2 release"])
        XCTAssertEqual(output.citations.count, 1)
        XCTAssertEqual(output.citations[0].url.absoluteString, "https://swift.org/blog/swift-6-2")
        XCTAssertTrue(output.content.contains("[1] Swift 6.2 released"))
        XCTAssertTrue(output.content.contains("not full pages"))
        XCTAssertEqual(output.userVisibleSummary, "Searched the web for \"swift 6.2 release\" — 1 result")
    }

    func testWebSearchReportsDisabledWebAccess() async {
        do {
            _ = try await WebSearchTool().execute(
                arguments: .object(["query": "anything"]),
                context: .testing(search: DisabledWebSearchProvider())
            )
            XCTFail("expected a failure")
        } catch let error as AppError {
            XCTAssertEqual(error, .webAccessDisabled)
            XCTAssertEqual(
                error.recoverySuggestion,
                "Turn on Web access in Settings › Web to let ScreenMate look things up."
            )
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testWebSearchRejectsAMissingQuery() async {
        do {
            _ = try await WebSearchTool().execute(arguments: .object([:]), context: .testing())
            XCTFail("expected a failure")
        } catch let error as AppError {
            XCTAssertEqual(error, .toolArgumentsInvalid(tool: "web_search", detail: "\"query\" is missing"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testChecklistFormatting() async throws {
        let output = try await MakeChecklistTool().execute(
            arguments: .object(["title": "Ship it", "items": .array(["Run tests", "Tag release"])]),
            context: .testing()
        )
        XCTAssertEqual(output.content, "### Ship it\n- [ ] Run tests\n- [ ] Tag release")
    }

    func testChecklistRejectsAnEmptyList() async {
        do {
            _ = try await MakeChecklistTool().execute(
                arguments: .object(["items": .array([])]),
                context: .testing()
            )
            XCTFail("expected a failure")
        } catch let error as AppError {
            XCTAssertEqual(error, .toolArgumentsInvalid(tool: "make_checklist", detail: "\"items\" was empty"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCurrentDateTimeUsesTheInjectedClock() async throws {
        let output = try await CurrentDateTimeTool().execute(
            arguments: .object([:]),
            context: .testing(now: Date(timeIntervalSince1970: 0))
        )
        XCTAssertTrue(output.content.contains("1970"))
    }

    func testCreateNoteWritesThroughThePort() async throws {
        let writer = SpyNoteWriter()
        let output = try await CreateNoteTool().execute(
            arguments: .object(["title": "Standup", "body": "- shipped capture"]),
            context: .testing(noteWriter: writer)
        )
        XCTAssertEqual(writer.notes, ["Standup"])
        XCTAssertEqual(output.userVisibleSummary, "Saved \"Standup\"")
    }
}
