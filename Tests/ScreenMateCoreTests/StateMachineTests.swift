import XCTest
@testable import ScreenMateCore

final class VoiceSessionMachineTests: XCTestCase {
    func testHappyPathPushToTalk() {
        var machine = VoiceSessionMachine()

        XCTAssertEqual(machine.handle(.startRequested(hasPermission: true)).first, .startEngine)
        XCTAssertTrue(machine.state.isMicrophoneOpen)

        machine.handle(.partialTranscript("summarise this"))
        XCTAssertEqual(machine.state.partialTranscript, "summarise this")

        machine.handle(.levelChanged(0.4))
        XCTAssertEqual(machine.state.level, 0.4)

        XCTAssertEqual(machine.handle(.stopRequested), [.stopEngine])
        XCTAssertFalse(machine.state.isMicrophoneOpen)

        XCTAssertEqual(
            machine.handle(.finalTranscript("summarise this page")),
            [.submit("summarise this page")]
        )
        XCTAssertEqual(machine.state, .idle)
    }

    func testPermissionIsRequestedWhenNotYetGranted() {
        var machine = VoiceSessionMachine()
        XCTAssertEqual(machine.handle(.startRequested(hasPermission: false)), [.requestPermission])
        XCTAssertEqual(machine.state, .requestingPermission)
        XCTAssertFalse(machine.state.isMicrophoneOpen, "the mic must stay closed until granted")

        XCTAssertEqual(machine.handle(.permissionGranted).first, .startEngine)
        XCTAssertTrue(machine.state.isMicrophoneOpen)
    }

    func testDeniedPermissionLeavesMicrophoneClosed() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: false))
        machine.handle(.permissionRefused(.microphonePermissionDenied))
        XCTAssertEqual(machine.state, .permissionDenied(.microphonePermissionDenied))
        XCTAssertFalse(machine.state.isMicrophoneOpen)
    }

    func testCancelDiscardsWithoutSubmitting() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        machine.handle(.partialTranscript("private thought"))

        let effects = machine.handle(.cancelRequested)
        XCTAssertTrue(effects.contains(.discard))
        XCTAssertFalse(effects.contains(where: { if case .submit = $0 { return true } else { return false } }))
        XCTAssertEqual(machine.state, .idle)
    }

    func testLateFinalTranscriptAfterCancelIsDropped() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        machine.handle(.stopRequested)
        machine.handle(.cancelRequested)

        // The recogniser finishes after the user already cancelled.
        let effects = machine.handle(.finalTranscript("should never be sent"))
        XCTAssertFalse(
            effects.contains(where: { if case .submit = $0 { return true } else { return false } }),
            "a cancelled recording must never be submitted"
        )
    }

    func testEmptyTranscriptIsNotSubmitted() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        machine.handle(.stopRequested)
        let effects = machine.handle(.finalTranscript("   \n "))
        XCTAssertEqual(effects, [.announce("Nothing was heard")])
    }

    func testFinalTranscriptWhileStillListeningStopsAndSubmits() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        let effects = machine.handle(.finalTranscript("hands free question"))
        XCTAssertEqual(effects, [.stopEngine, .submit("hands free question")])
        XCTAssertEqual(machine.state, .idle)
    }

    func testDoubleStartDoesNotRestartTheEngine() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        XCTAssertEqual(machine.handle(.startRequested(hasPermission: true)), [])
    }

    func testStopTwiceIsIdempotent() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        XCTAssertEqual(machine.handle(.stopRequested), [.stopEngine])
        XCTAssertEqual(machine.handle(.stopRequested), [])
    }

    func testRecognizerFailureStopsTheEngineAndDiscards() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        let effects = machine.handle(.recognizerFailed(.speechRecognitionFailed(detail: nil)))
        XCTAssertTrue(effects.contains(.stopEngine))
        XCTAssertTrue(effects.contains(.discard))
        XCTAssertEqual(machine.state, .failed(.speechRecognitionFailed(detail: nil)))
    }

    func testPermissionRevokedMidRecordingClosesTheMicrophone() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        let effects = machine.permissionRevoked()
        XCTAssertTrue(effects.contains(.stopEngine))
        XCTAssertFalse(machine.state.isMicrophoneOpen)
        XCTAssertEqual(
            machine.state,
            .permissionDenied(.permissionRevokedWhileRunning(capability: "Microphone"))
        )
    }

    func testRetryAfterFailureWorks() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        machine.handle(.recognizerFailed(.speechRecognitionFailed(detail: nil)))
        XCTAssertEqual(machine.handle(.startRequested(hasPermission: true)).first, .startEngine)
    }

    func testLevelIsClampedToUnitRange() {
        var machine = VoiceSessionMachine()
        machine.handle(.startRequested(hasPermission: true))
        machine.handle(.levelChanged(4.2))
        XCTAssertEqual(machine.state.level, 1)
        machine.handle(.levelChanged(-1))
        XCTAssertEqual(machine.state.level, 0)
    }
}

final class ScreenCaptureMachineTests: XCTestCase {
    func testCaptureIsRefusedWhileScreenAwarenessIsOff() {
        var machine = ScreenCaptureMachine()
        let effects = machine.handle(.captureRequested(
            scope: .activeWindow,
            hasPermission: true,
            awarenessEnabled: false
        ))
        XCTAssertEqual(effects, [.promptToEnableScreenAwareness])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertFalse(machine.state.isCapturing, "no pixels may be read while awareness is off")
    }

    func testPermissionIsRequestedBeforeAnyCapture() {
        var machine = ScreenCaptureMachine()
        let effects = machine.handle(.captureRequested(
            scope: .activeDisplay,
            hasPermission: false,
            awarenessEnabled: true
        ))
        XCTAssertEqual(effects, [.requestPermission])
        XCTAssertEqual(machine.state, .requestingPermission)
    }

    func testRegionScopeShowsTheSelectorFirst() {
        var machine = ScreenCaptureMachine()
        let effects = machine.handle(.captureRequested(
            scope: .selectedRegion,
            hasPermission: true,
            awarenessEnabled: true
        ))
        XCTAssertEqual(effects.first, .showRegionSelector)
        XCTAssertEqual(machine.state, .selectingRegion)

        XCTAssertEqual(machine.handle(.regionSelected), [.performCapture(.selectedRegion)])
        XCTAssertEqual(machine.state, .capturing(.selectedRegion))
    }

    func testCapturedImageWaitsForApprovalWhenPreviewIsRequired() {
        var machine = ScreenCaptureMachine(requiresPreview: true)
        machine.handle(.captureRequested(scope: .activeWindow, hasPermission: true, awarenessEnabled: true))
        let context = ScreenContext.fixture()
        machine.handle(.captured(context))
        XCTAssertEqual(machine.state, .previewing(context))

        machine.handle(.approved)
        XCTAssertEqual(machine.state, .attached(context))
        XCTAssertEqual(machine.state.pendingContext, context)
    }

    func testPreviewCanBeSkippedWhenTheUserTurnedItOff() {
        var machine = ScreenCaptureMachine(requiresPreview: false)
        machine.handle(.captureRequested(scope: .activeWindow, hasPermission: true, awarenessEnabled: true))
        let context = ScreenContext.fixture()
        machine.handle(.captured(context))
        XCTAssertEqual(machine.state, .attached(context))
    }

    func testDiscardingAPreviewFreesTheImage() {
        var machine = ScreenCaptureMachine()
        machine.handle(.captureRequested(scope: .activeWindow, hasPermission: true, awarenessEnabled: true))
        machine.handle(.captured(.fixture()))
        let effects = machine.handle(.cancelled)
        XCTAssertTrue(effects.contains(.discardImage))
        XCTAssertNil(machine.state.pendingContext)
    }

    func testSensitiveAppBlocksCaptureWithAReason() {
        var machine = ScreenCaptureMachine()
        machine.handle(.captureRequested(scope: .activeWindow, hasPermission: true, awarenessEnabled: true))
        let effects = machine.handle(.blockedBySensitiveApp(reason: "1Password is not captured."))
        XCTAssertTrue(effects.contains(.discardImage))
        XCTAssertEqual(machine.state, .blocked(reason: "1Password is not captured."))
        XCTAssertNil(machine.state.pendingContext)
    }

    func testCaptureFailureDiscardsAndReports() {
        var machine = ScreenCaptureMachine()
        machine.handle(.captureRequested(scope: .activeDisplay, hasPermission: true, awarenessEnabled: true))
        let effects = machine.handle(.captureFailed(.screenCaptureFailed(detail: "display asleep")))
        XCTAssertTrue(effects.contains(.discardImage))
        XCTAssertEqual(machine.state, .failed(.screenCaptureFailed(detail: "display asleep")))
    }

    func testConsumingAnAttachmentReleasesTheImage() {
        var machine = ScreenCaptureMachine()
        machine.handle(.captureRequested(scope: .activeWindow, hasPermission: true, awarenessEnabled: true))
        machine.handle(.captured(.fixture()))
        machine.handle(.approved)
        XCTAssertEqual(machine.handle(.consumed), [.discardImage])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.state.pendingContext)
    }

    func testTurningScreenAwarenessOffDropsAPendingCapture() {
        var machine = ScreenCaptureMachine()
        machine.handle(.captureRequested(scope: .activeWindow, hasPermission: true, awarenessEnabled: true))
        machine.handle(.captured(.fixture()))
        machine.handle(.approved)

        let effects = machine.screenAwarenessDisabled()
        XCTAssertTrue(effects.contains(.discardImage))
        XCTAssertNil(machine.state.pendingContext)
        XCTAssertEqual(machine.state, .idle)
    }

    func testRegionSelectionCanBeCancelledWithEscape() {
        var machine = ScreenCaptureMachine()
        machine.handle(.captureRequested(scope: .selectedRegion, hasPermission: true, awarenessEnabled: true))
        let effects = machine.handle(.cancelled)
        XCTAssertTrue(effects.contains(.discardImage))
        XCTAssertEqual(machine.state, .idle)
    }

    func testPermissionDenialIsRecoverable() {
        var machine = ScreenCaptureMachine()
        machine.handle(.captureRequested(scope: .activeWindow, hasPermission: false, awarenessEnabled: true))
        machine.handle(.permissionRefused(.screenRecordingPermissionDenied))
        XCTAssertEqual(machine.state, .permissionDenied(.screenRecordingPermissionDenied))

        machine.handle(.cancelled)
        XCTAssertEqual(machine.state, .idle)

        let effects = machine.handle(.captureRequested(
            scope: .activeWindow,
            hasPermission: true,
            awarenessEnabled: true
        ))
        XCTAssertTrue(effects.contains(.performCapture(.activeWindow)))
    }
}

final class ScreenContextBoxTests: XCTestCase {
    func testDiscardReleasesTheImage() {
        let box = ScreenContextBox(.fixture())
        XCTAssertNotNil(box.value)
        box.discard()
        XCTAssertNil(box.value)
    }

    func testAttachmentProjectionNeverCarriesPixels() {
        let context = ScreenContext.fixture(extractedText: "secret-ish text", bytes: 2048)
        let attachment = context.attachment(includeExtractedText: false)
        XCTAssertNil(attachment.extractedText)
        XCTAssertEqual(attachment.byteCount, 2048)
        XCTAssertEqual(attachment.pixelWidth, 1440)

        // MessageAttachment is the only thing persisted, and it has no image field.
        let encoded = try? JSONEncoder().encode(attachment)
        let json = String(decoding: encoded ?? Data(), as: UTF8.self)
        XCTAssertFalse(json.contains("imageData"))
    }

    func testAttachmentCanCarryOCRTextWhenTheUserOptedIn() {
        let attachment = ScreenContext.fixture(extractedText: "error TS2345")
            .attachment(includeExtractedText: true)
        XCTAssertEqual(attachment.extractedText, "error TS2345")
    }

    func testRedactionSummaryIsCarriedIntoTheAttachment() {
        let attachment = ScreenContext
            .fixture(findings: [RedactionFinding(category: .apiKey, count: 1)])
            .attachment(includeExtractedText: false)
        XCTAssertEqual(attachment.redactionSummary, "Removed 1 API key before sending.")
    }
}
