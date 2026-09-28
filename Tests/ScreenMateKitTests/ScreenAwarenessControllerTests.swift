import CoreGraphics
import XCTest
@testable import ScreenMateCore
@testable import ScreenMateKit

@MainActor
final class ScreenAwarenessControllerTests: XCTestCase {
    private func makeController(
        awarenessEnabled: Bool = true,
        requiresPreview: Bool = true,
        hasPermission: Bool = true
    ) -> (ScreenAwarenessController, FakeScreenCapturer, FakePermissionProbe) {
        var settings = AppSettings()
        settings.screenAwarenessEnabled = awarenessEnabled
        settings.sendScreenContentToProvider = awarenessEnabled
        settings.alwaysPreviewBeforeSending = requiresPreview
        settings.defaultCaptureScope = .activeWindow

        let probe = FakePermissionProbe(states: [
            .screenRecording: hasPermission ? .granted : .notDetermined,
        ])
        let capturer = FakeScreenCapturer()
        let controller = ScreenAwarenessController(
            capturer: capturer,
            permissions: PermissionCenter(probe: probe, observeActivation: false),
            settingsProvider: { settings }
        )
        return (controller, capturer, probe)
    }

    private func settle() async {
        for _ in 0..<6 { await Task.yield() }
    }

    func testCaptureIsRefusedWhileScreenAwarenessIsOff() async {
        let (controller, capturer, _) = makeController(awarenessEnabled: false)
        var prompted = false
        controller.onNeedsScreenAwareness = { prompted = true }

        controller.capture()
        await settle()

        XCTAssertTrue(prompted)
        XCTAssertTrue(capturer.captureCalls.isEmpty, "no pixels may be read while awareness is off")
        XCTAssertEqual(controller.state, .idle)
    }

    func testCaptureWaitsForPreviewApproval() async {
        let (controller, capturer, _) = makeController()
        controller.capture()
        await settle()

        XCTAssertEqual(capturer.captureCalls.count, 1)
        XCTAssertEqual(capturer.captureCalls[0].scope, .activeWindow)
        XCTAssertNotNil(controller.previewContext)
        XCTAssertNil(controller.attachedContext, "nothing is attached until the user approves")

        controller.approvePreview()
        XCTAssertNotNil(controller.attachedContext)
        XCTAssertNil(controller.previewContext)
    }

    func testPreviewCanBeSkipped() async {
        let (controller, _, _) = makeController(requiresPreview: false)
        controller.capture()
        await settle()
        XCTAssertNotNil(controller.attachedContext)
    }

    func testDiscardingReleasesTheCapture() async {
        let (controller, _, _) = makeController()
        controller.capture()
        await settle()
        controller.discard()
        XCTAssertNil(controller.previewContext)
        XCTAssertNil(controller.attachedContext)
        XCTAssertEqual(controller.state, .idle)
    }

    func testPermissionIsRequestedBeforeCapturing() async {
        let (controller, capturer, probe) = makeController(hasPermission: false)
        controller.capture()

        XCTAssertTrue(capturer.captureCalls.isEmpty)
        await settle()

        XCTAssertEqual(probe.requested, [.screenRecording])
        XCTAssertEqual(capturer.captureCalls.count, 1)
    }

    func testDeniedPermissionStopsTheCapture() async {
        let (controller, capturer, probe) = makeController(hasPermission: false)
        probe.requestResults[.screenRecording] = .denied

        controller.capture()
        await settle()

        XCTAssertTrue(capturer.captureCalls.isEmpty)
        XCTAssertEqual(controller.state, .permissionDenied(.screenRecordingPermissionDenied))
    }

    func testSensitiveAppBlockIsSurfacedWithItsReason() async {
        let (controller, capturer, _) = makeController()
        capturer.errorToThrow = ScreenCaptureService.BlockedBySensitiveApp(
            reason: "ScreenMate does not capture 1Password."
        )
        controller.capture()
        await settle()

        XCTAssertEqual(controller.state, .blocked(reason: "ScreenMate does not capture 1Password."))
        XCTAssertNil(controller.attachedContext)
    }

    func testCaptureFailureIsReported() async {
        let (controller, capturer, _) = makeController()
        capturer.errorToThrow = AppError.screenCaptureFailed(detail: "display asleep")
        var reported: [AppError] = []
        controller.onError = { reported.append($0) }

        controller.capture()
        await settle()

        XCTAssertEqual(reported, [.screenCaptureFailed(detail: "display asleep")])
        XCTAssertNil(controller.attachedContext)
    }

    func testReleasingAnAttachmentClearsIt() async {
        let (controller, _, _) = makeController(requiresPreview: false)
        controller.capture()
        await settle()
        XCTAssertNotNil(controller.attachedContext)

        controller.releaseAttachment()
        XCTAssertNil(controller.attachedContext)
    }

    func testTurningAwarenessOffDropsAHeldCapture() async {
        let (controller, _, _) = makeController(requiresPreview: false)
        controller.capture()
        await settle()
        XCTAssertNotNil(controller.attachedContext)

        controller.screenAwarenessDisabled()
        XCTAssertNil(controller.attachedContext)
        XCTAssertEqual(controller.state, .idle)
    }

    func testRevokedPermissionClearsState() async {
        let (controller, _, _) = makeController(requiresPreview: false)
        controller.capture()
        await settle()

        controller.permissionRevoked()
        XCTAssertNil(controller.attachedContext)
        XCTAssertEqual(
            controller.state,
            .permissionDenied(.permissionRevokedWhileRunning(capability: "Screen Recording"))
        )
    }

    func testScopeIsPassedThrough() async {
        let (controller, capturer, _) = makeController()
        controller.capture(scope: .activeDisplay)
        await settle()
        XCTAssertEqual(capturer.captureCalls.last?.scope, .activeDisplay)
    }

    func testIsReadingScreenIsFalseWhenIdle() async {
        let (controller, _, _) = makeController()
        XCTAssertFalse(controller.isReadingScreen)
        controller.capture()
        await settle()
        // The capture has finished by the time the preview is up.
        XCTAssertFalse(controller.isReadingScreen)
    }
}

final class CapturedImageEncoderTests: XCTestCase {
    /// A solid-colour image of a given size, built without touching the screen.
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("CGContext could not be created in this environment")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw XCTSkip("CGContext produced no image")
        }
        return image
    }

    func testLargeRetinaCaptureIsDownscaledToTheBudget() throws {
        let encoder = CapturedImageEncoder(maxLongestEdge: 800, byteBudget: 8 * 1024 * 1024)
        let encoded = try encoder.encode(try makeImage(width: 5120, height: 2880))

        XCTAssertLessThanOrEqual(max(encoded.pixelWidth, encoded.pixelHeight), 800)
        // Aspect ratio is preserved.
        let ratio = Double(encoded.pixelWidth) / Double(encoded.pixelHeight)
        XCTAssertEqual(ratio, 5120.0 / 2880.0, accuracy: 0.02)
        XCTAssertFalse(encoded.data.isEmpty)
    }

    func testSmallImageIsLeftAtItsOriginalSize() throws {
        let encoder = CapturedImageEncoder(maxLongestEdge: 1568)
        let encoded = try encoder.encode(try makeImage(width: 400, height: 300))
        XCTAssertEqual(encoded.pixelWidth, 400)
        XCTAssertEqual(encoded.pixelHeight, 300)
    }

    func testEncodingFallsBackToJPEGUnderATightBudget() throws {
        // 2 KB is far too small for a PNG of this size, so JPEG must be chosen.
        let encoder = CapturedImageEncoder(maxLongestEdge: 600, byteBudget: 20 * 1024)
        let encoded = try encoder.encode(try makeImage(width: 1200, height: 900))
        XCTAssertLessThanOrEqual(encoded.data.count, 20 * 1024)
        XCTAssertTrue(["image/png", "image/jpeg"].contains(encoded.mimeType))
    }

    func testCroppingClampsToTheImageBounds() throws {
        let encoder = CapturedImageEncoder()
        let image = try makeImage(width: 200, height: 100)
        let cropped = try encoder.crop(image, to: CGRect(x: 150, y: 50, width: 200, height: 200))
        XCTAssertEqual(cropped.width, 50)
        XCTAssertEqual(cropped.height, 50)
    }

    func testCroppingEntirelyOutsideTheImageFails() throws {
        let encoder = CapturedImageEncoder()
        let image = try makeImage(width: 200, height: 100)
        XCTAssertThrowsError(try encoder.crop(image, to: CGRect(x: 500, y: 500, width: 10, height: 10))) { error in
            XCTAssertEqual(
                error as? AppError,
                .screenCaptureFailed(detail: "the selected area was outside the display")
            )
        }
    }
}
