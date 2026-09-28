import XCTest
@testable import ScreenMateCore

final class AppErrorTests: XCTestCase {
    /// Every error the app can show. Kept exhaustive on purpose: the point of
    /// the type is that no failure reaches the user without a next step.
    private let allErrors: [AppError] = [
        .missingAPIKey(provider: "Anthropic"),
        .invalidAPIKey(provider: "Anthropic"),
        .modelUnavailable(model: "gpt-9"),
        .unsupportedOSVersion(required: "macOS 14"),
        .networkUnavailable,
        .requestTimedOut,
        .rateLimited(retryAfter: 30),
        .rateLimited(retryAfter: nil),
        .providerUnavailable(status: 503, detail: "overloaded"),
        .malformedProviderResponse(detail: nil),
        .microphonePermissionDenied,
        .speechRecognitionPermissionDenied,
        .screenRecordingPermissionDenied,
        .accessibilityPermissionDenied,
        .permissionRevokedWhileRunning(capability: "Microphone"),
        .noAudioInputDevice,
        .speechRecognitionUnavailable(locale: "en-US"),
        .speechRecognitionFailed(detail: nil),
        .textToSpeechFailed(detail: nil),
        .screenCaptureFailed(detail: nil),
        .noCapturableDisplay,
        .imageTooLarge(bytes: 9_000_000, limit: 4_000_000),
        .screenAwarenessDisabled,
        .screenSharingWithProviderDisabled,
        .webAccessDisabled,
        .webSearchNotConfigured(provider: "Brave Search"),
        .webSearchFailed(detail: nil),
        .emptyInput,
        .toolNotFound(name: "x"),
        .toolArgumentsInvalid(tool: "x", detail: "bad"),
        .toolExecutionFailed(tool: "x", detail: "bad"),
        .storageFailure(detail: "disk full"),
        .keychainFailure(status: -25300),
    ]

    func testEveryErrorHasAMessage() {
        for error in allErrors {
            XCTAssertNotNil(error.errorDescription, "\(error) has no message")
            XCTAssertFalse(error.errorDescription!.isEmpty, "\(error) has an empty message")
        }
    }

    func testEveryErrorTheUserDidNotCauseOffersANextStep() {
        for error in allErrors where !error.isUserInitiated {
            XCTAssertNotNil(error.recoverySuggestion, "\(error) leaves the user with nowhere to go")
        }
    }

    func testUserInitiatedErrorsAreQuiet() {
        for error in [AppError.cancelled, .screenCaptureCancelled, .toolConfirmationDeclined(tool: "x")] {
            XCTAssertTrue(error.isUserInitiated)
            XCTAssertNil(error.recoverySuggestion)
        }
    }

    func testPermissionMessagesNameTheExactSystemSettingsPane() {
        XCTAssertEqual(
            AppError.screenRecordingPermissionDenied.recoverySuggestion?
                .contains("Screen & System Audio Recording"),
            true
        )
        XCTAssertEqual(
            AppError.microphonePermissionDenied.recoverySuggestion?.contains("Microphone"),
            true
        )
    }

    func testRetryAfterIsQuotedInTheSuggestion() {
        XCTAssertEqual(
            AppError.rateLimited(retryAfter: 45).recoverySuggestion,
            "Wait about 45 seconds and try again."
        )
    }

    func testImageSizeIsHumanReadable() {
        let message = AppError.imageTooLarge(bytes: 9_000_000, limit: 4_000_000).errorDescription
        XCTAssertEqual(message?.contains("MB"), true)
    }

    func testURLErrorsAreMappedToSpecificCases() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(AppError.wrapping(offline), .networkUnavailable)

        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(AppError.wrapping(timeout), .requestTimedOut)

        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(AppError.wrapping(cancelled), .cancelled)
    }

    func testWrappingAnAppErrorIsIdentity() {
        XCTAssertEqual(AppError.wrapping(AppError.emptyInput), .emptyInput)
    }

    func testWrappingCancellationErrorGivesCancelled() {
        XCTAssertEqual(AppError.wrapping(CancellationError()), .cancelled)
    }

    func testRetryableFlagsAreSensible() {
        XCTAssertTrue(AppError.networkUnavailable.isRetryable)
        XCTAssertTrue(AppError.rateLimited(retryAfter: nil).isRetryable)
        XCTAssertFalse(AppError.missingAPIKey(provider: "x").isRetryable)
        XCTAssertFalse(AppError.screenRecordingPermissionDenied.isRetryable)
    }
}

final class ProviderErrorMapperTests: XCTestCase {
    private let mapper = ProviderErrorMapper(providerDisplayName: "TestProvider")

    func testExtractsNestedErrorMessage() {
        let message = ProviderErrorMapper.extractMessage(from: #"{"error":{"message":"bad request"}}"#)
        XCTAssertEqual(message, "bad request")
    }

    func testFallsBackToTheRawBody() {
        let message = ProviderErrorMapper.extractMessage(from: "upstream exploded")
        XCTAssertEqual(message, "upstream exploded")
    }

    func testModelShapedBadRequestBecomesModelUnavailable() {
        let error = mapper.error(
            for: HTTPResponseMetadata(statusCode: 400),
            body: #"{"error":{"message":"model: not_found"}}"#,
            requestedModel: "gpt-9"
        )
        XCTAssertEqual(error, .modelUnavailable(model: "gpt-9"))
    }

    func testRetryAfterHeaderIsParsed() {
        let error = mapper.error(
            for: HTTPResponseMetadata(statusCode: 429, headers: ["retry-after": "12"]),
            body: nil,
            requestedModel: nil
        )
        XCTAssertEqual(error, .rateLimited(retryAfter: 12))
    }

    func testHeaderLookupIsCaseInsensitive() {
        let metadata = HTTPResponseMetadata(statusCode: 200, headers: ["Retry-After": "5"])
        XCTAssertEqual(metadata.retryAfterSeconds, 5)
    }
}

final class WebSearchProviderTests: XCTestCase {
    func testBraveResultsAreParsedAndMarkupIsStripped() async throws {
        let body = """
        {"web":{"results":[
          {"title":"<strong>Swift</strong> 6.2 released","url":"https://swift.org/blog","description":"Now <strong>available</strong> &amp; stable."}
        ]}}
        """
        let provider = BraveWebSearchProvider(apiKey: "key", transport: MockHTTPTransport(stub: .json(body)))
        let response = try await provider.search(query: "swift 6.2", maxResults: 5)

        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].title, "Swift 6.2 released")
        XCTAssertEqual(response.results[0].snippet, "Now available & stable.")
        XCTAssertEqual(response.results[0].displayHost, "swift.org")
    }

    func testBraveSendsTheSubscriptionTokenAndQuery() async throws {
        let transport = MockHTTPTransport(stub: .json(#"{"web":{"results":[]}}"#))
        let provider = BraveWebSearchProvider(apiKey: "brave-key", transport: transport)
        _ = try await provider.search(query: "swift", maxResults: 3)

        let request = transport.recordedRequests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "brave-key")
        XCTAssertEqual(request.url?.query?.contains("q=swift"), true)
        XCTAssertEqual(request.url?.query?.contains("count=3"), true)
    }

    func testBraveUnauthorizedReadsAsASearchConfigurationProblem() async {
        let provider = BraveWebSearchProvider(
            apiKey: "bad",
            transport: MockHTTPTransport(stub: .json("{}", statusCode: 401))
        )
        await assertThrows(.webSearchNotConfigured(provider: "Brave Search")) {
            _ = try await provider.search(query: "swift", maxResults: 3)
        }
    }

    func testBraveRateLimitIsSurfacedAsRateLimited() async {
        let provider = BraveWebSearchProvider(
            apiKey: "key",
            transport: MockHTTPTransport(stub: .json("{}", statusCode: 429, headers: ["Retry-After": "7"]))
        )
        await assertThrows(.rateLimited(retryAfter: 7)) {
            _ = try await provider.search(query: "swift", maxResults: 3)
        }
    }

    func testMissingKeyIsReportedBeforeAnyRequest() async {
        let transport = MockHTTPTransport(stub: .json("{}"))
        let provider = BraveWebSearchProvider(apiKey: "", transport: transport)
        await assertThrows(.webSearchNotConfigured(provider: "Brave Search")) {
            _ = try await provider.search(query: "swift", maxResults: 3)
        }
        XCTAssertTrue(transport.recordedRequests.isEmpty)
    }

    func testEmptyQueryIsRejected() async {
        let provider = BraveWebSearchProvider(apiKey: "key", transport: MockHTTPTransport(stub: .json("{}")))
        await assertThrows(.emptyInput) {
            _ = try await provider.search(query: "   ", maxResults: 3)
        }
    }

    func testTavilyResultsAreParsed() async throws {
        let body = """
        {"results":[{"title":"Docs","url":"https://example.com/docs","content":"Reference material."}]}
        """
        let provider = TavilyWebSearchProvider(apiKey: "key", transport: MockHTTPTransport(stub: .json(body)))
        let response = try await provider.search(query: "docs", maxResults: 5)
        XCTAssertEqual(response.results[0].title, "Docs")
        XCTAssertEqual(response.results[0].snippet, "Reference material.")
    }

    func testDisabledProviderAlwaysReportsWebAccessOff() async {
        await assertThrows(.webAccessDisabled) {
            _ = try await DisabledWebSearchProvider().search(query: "anything", maxResults: 5)
        }
    }

    func testCatalogReturnsTheDisabledProviderWhenWebAccessIsOff() {
        let catalog = SearchCatalog.standard(transport: MockHTTPTransport(stub: .json("{}")))
        let provider = catalog.makeProvider(id: "brave", apiKey: "key", webAccessEnabled: false)
        XCTAssertTrue(provider is DisabledWebSearchProvider)
    }

    func testCatalogSwitchesBetweenSearchBackends() {
        let catalog = SearchCatalog.standard(transport: MockHTTPTransport(stub: .json("{}")))
        XCTAssertTrue(catalog.makeProvider(id: "brave", apiKey: "k", webAccessEnabled: true) is BraveWebSearchProvider)
        XCTAssertTrue(catalog.makeProvider(id: "tavily", apiKey: "k", webAccessEnabled: true) is TavilyWebSearchProvider)
    }

    func testPromptRepresentationLabelsSnippetsAsUnverified() {
        let response = WebSearchResponse(
            query: "swift",
            results: [WebSearchResult(title: "T", url: URL(string: "https://a.com")!, snippet: "S")],
            retrievedAt: Date(timeIntervalSince1970: 1_700_000_000),
            providerDisplayName: "Stub"
        )
        let text = response.promptRepresentation()
        XCTAssertTrue(text.contains("not full pages"))
        XCTAssertTrue(text.contains("unverified"))
        XCTAssertTrue(text.contains("[1] T"))
    }

    func testEmptyResultsAreStatedExplicitly() {
        let response = WebSearchResponse(
            query: "nothing",
            results: [],
            retrievedAt: Date(),
            providerDisplayName: "Stub"
        )
        XCTAssertEqual(response.promptRepresentation(), "No results were returned for \"nothing\".")
    }
}

final class AssistantActivityTests: XCTestCase {
    func testOnlyListeningStatesReportAnOpenMicrophone() {
        XCTAssertTrue(AssistantActivity.listening(level: 0.2).isCapturingAudio)
        XCTAssertTrue(AssistantActivity.transcribing.isCapturingAudio)
        for activity: AssistantActivity in [.idle, .thinking, .streaming, .speaking, .readingScreen] {
            XCTAssertFalse(activity.isCapturingAudio, "\(activity) must not claim the mic is open")
        }
    }

    func testOnlyReadingScreenReportsScreenAccess() {
        XCTAssertTrue(AssistantActivity.readingScreen.isReadingScreen)
        for activity: AssistantActivity in [.idle, .thinking, .streaming, .listening(level: 0)] {
            XCTAssertFalse(activity.isReadingScreen)
        }
    }

    func testIdleAndFailedAreNotBusy() {
        XCTAssertFalse(AssistantActivity.idle.isBusy)
        XCTAssertFalse(AssistantActivity.failed(MessageFailure(.networkUnavailable)).isBusy)
        XCTAssertTrue(AssistantActivity.thinking.isBusy)
    }

    func testInterruptibleStatesCanBeStopped() {
        XCTAssertTrue(AssistantActivity.streaming.isInterruptible)
        XCTAssertTrue(AssistantActivity.speaking.isInterruptible)
        XCTAssertFalse(AssistantActivity.idle.isInterruptible)
    }

    func testEveryStateHasAnAccessibilityAnnouncement() {
        let states: [AssistantActivity] = [
            .idle, .listening(level: 0.5), .transcribing, .readingScreen,
            .searchingWeb(query: "swift"), .thinking, .streaming,
            .runningTool(name: "web_search"), .awaitingToolConfirmation(name: "open_url"),
            .speaking, .failed(MessageFailure(.networkUnavailable)),
        ]
        for state in states {
            XCTAssertFalse(state.accessibilityAnnouncement.isEmpty)
            XCTAssertFalse(state.shortLabel.isEmpty)
        }
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let value = JSONValue.object([
            "text": "hello",
            "count": 3,
            "ratio": 0.5,
            "flag": true,
            "nothing": .null,
            "list": .array([1, 2, 3]),
        ])
        let encoded = try value.encodedString()
        XCTAssertEqual(try JSONValue.decode(from: encoded), value)
    }

    func testKeysAreSortedForStableOutput() throws {
        let value = JSONValue.object(["b": 1, "a": 2])
        XCTAssertEqual(try value.encodedString(), #"{"a":2,"b":1}"#)
    }

    func testAccessorsCoerceSensibly() {
        XCTAssertEqual(JSONValue.string("42").intValue, 42)
        XCTAssertEqual(JSONValue.number(7).intValue, 7)
        XCTAssertEqual(JSONValue.string("true").boolValue, true)
        XCTAssertNil(JSONValue.null.stringValue)
    }

    func testSubscriptReturnsNilForNonObjects() {
        XCTAssertNil(JSONValue.string("x")["key"])
    }
}
