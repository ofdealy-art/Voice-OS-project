import XCTest
@testable import ScreenMateCore
@testable import ScreenMateKit

@MainActor
final class VoiceControllerTests: XCTestCase {
    private func makeController(
        permissions granted: Bool = true,
        settings: AppSettings = AppSettings()
    ) -> (VoiceController, FakeSpeechTranscriber, FakePermissionProbe) {
        let probe = FakePermissionProbe(states: granted
            ? [.microphone: .granted, .speechRecognition: .granted]
            : [.microphone: .notDetermined, .speechRecognition: .notDetermined])
        let transcriber = FakeSpeechTranscriber()
        let controller = VoiceController(
            transcriber: transcriber,
            permissions: PermissionCenter(probe: probe, observeActivation: false),
            settingsProvider: { settings }
        )
        return (controller, transcriber, probe)
    }

    /// Lets the controller's internal `Task { @MainActor }` hops run.
    private func settle() async {
        for _ in 0..<6 { await Task.yield() }
    }

    func testStartOpensTheMicrophoneWhenPermitted() async {
        let (controller, transcriber, _) = makeController()
        controller.start()
        await settle()

        XCTAssertEqual(transcriber.startCount, 1)
        XCTAssertTrue(controller.isListening)
    }

    func testMicrophoneStaysClosedUntilPermissionIsGranted() async {
        let (controller, transcriber, probe) = makeController(permissions: false)
        controller.start()

        XCTAssertEqual(transcriber.startCount, 0, "the mic must not open before the prompt is answered")
        await settle()

        XCTAssertEqual(probe.requested, [.microphone, .speechRecognition])
        XCTAssertEqual(transcriber.startCount, 1)
    }

    func testRefusedPermissionLeavesTheMicrophoneClosed() async {
        let (controller, transcriber, probe) = makeController(permissions: false)
        probe.requestResults[.microphone] = .denied
        controller.start()
        await settle()

        XCTAssertEqual(transcriber.startCount, 0)
        XCTAssertFalse(controller.isListening)
        XCTAssertEqual(controller.state, .permissionDenied(.microphonePermissionDenied))
    }

    func testPartialTranscriptIsPublished() async {
        let (controller, transcriber, _) = makeController()
        controller.start()
        await settle()

        transcriber.emit(.partial("what am I"))
        await settle()
        XCTAssertEqual(controller.partialTranscript, "what am I")

        transcriber.emit(.partial("what am I looking at"))
        await settle()
        XCTAssertEqual(controller.partialTranscript, "what am I looking at")
    }

    func testFinalTranscriptIsHandedOff() async {
        let (controller, transcriber, _) = makeController()
        var submitted: [String] = []
        controller.onTranscript = { submitted.append($0) }

        controller.start()
        await settle()
        controller.stop()
        await settle()
        transcriber.emit(.final("summarise this page"))
        await settle()

        XCTAssertEqual(submitted, ["summarise this page"])
        XCTAssertEqual(transcriber.stopCount, 1)
        XCTAssertFalse(controller.isListening)
    }

    func testCancelDiscardsTheTranscript() async {
        let (controller, transcriber, _) = makeController()
        var submitted: [String] = []
        controller.onTranscript = { submitted.append($0) }

        controller.start()
        await settle()
        transcriber.emit(.partial("something private"))
        await settle()
        controller.cancel()
        await settle()

        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(transcriber.cancelCount, 1)
        XCTAssertFalse(transcriber.isOpen)
        XCTAssertFalse(controller.isListening)
    }

    func testStartWhileSpeakingAsksTheAssistantToStop() async {
        let (controller, _, _) = makeController()
        var interrupted = false
        controller.onWillStartListening = { interrupted = true }

        controller.start()
        await settle()
        XCTAssertTrue(interrupted)
    }

    func testTranscriberFailureSurfacesAsAFailedState() async {
        let (controller, transcriber, _) = makeController()
        controller.start()
        await settle()

        transcriber.fail(AppError.speechRecognitionFailed(detail: "engine died"))
        await settle()

        XCTAssertEqual(controller.state, .failed(.speechRecognitionFailed(detail: "engine died")))
        XCTAssertFalse(controller.isListening)
    }

    func testStartFailureIsReportedWithoutOpeningTheMicrophone() async {
        let (controller, transcriber, _) = makeController()
        transcriber.errorToThrowOnStart = AppError.noAudioInputDevice
        controller.start()
        await settle()

        XCTAssertEqual(controller.state, .failed(.noAudioInputDevice))
        XCTAssertFalse(transcriber.isOpen)
    }

    func testRevokedPermissionClosesTheMicrophoneMidRecording() async {
        let (controller, transcriber, _) = makeController()
        controller.start()
        await settle()
        XCTAssertTrue(transcriber.isOpen)

        controller.permissionRevoked()
        await settle()

        XCTAssertFalse(controller.isListening)
        XCTAssertEqual(
            controller.state,
            .permissionDenied(.permissionRevokedWhileRunning(capability: "Microphone"))
        )
    }

    func testSelectedMicrophoneAndLocaleArePassedThrough() async {
        var settings = AppSettings()
        settings.selectedMicrophoneUID = "AppleUSBAudioEngine:Blue:Yeti"
        settings.speechRecognitionLocaleIdentifier = "en-GB"
        let (controller, transcriber, _) = makeController(settings: settings)

        controller.start()
        await settle()

        XCTAssertEqual(transcriber.lastMicrophoneUID, "AppleUSBAudioEngine:Blue:Yeti")
        XCTAssertEqual(transcriber.lastLocale?.identifier, "en-GB")
    }

    func testToggleStartsThenStops() async {
        let (controller, transcriber, _) = makeController()
        controller.toggle()
        await settle()
        XCTAssertTrue(controller.isListening)

        controller.toggle()
        await settle()
        XCTAssertFalse(controller.isListening)
        XCTAssertEqual(transcriber.stopCount, 1)
    }

    func testLevelsFeedTheWaveform() async {
        let (controller, transcriber, _) = makeController()
        controller.start()
        await settle()

        transcriber.emit(.level(0.8))
        await settle()
        XCTAssertEqual(controller.levels.last, 0.8)
    }
}
