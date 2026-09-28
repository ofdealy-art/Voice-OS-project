import XCTest
@testable import ScreenMateCore
@testable import ScreenMateKit

@MainActor
final class PermissionCenterTests: XCTestCase {
    func testReadsInitialStatesFromTheProbe() {
        let probe = FakePermissionProbe(states: [
            .microphone: .granted,
            .speechRecognition: .denied,
            .screenRecording: .notDetermined,
            .accessibility: .restricted,
        ])
        let center = PermissionCenter(probe: probe, observeActivation: false)

        XCTAssertEqual(center.state(of: .microphone), .granted)
        XCTAssertEqual(center.state(of: .speechRecognition), .denied)
        XCTAssertEqual(center.state(of: .screenRecording), .notDetermined)
        XCTAssertEqual(center.state(of: .accessibility), .restricted)
    }

    func testVoiceNeedsBothMicrophoneAndSpeechRecognition() {
        let probe = FakePermissionProbe(states: [.microphone: .granted, .speechRecognition: .denied])
        let center = PermissionCenter(probe: probe, observeActivation: false)
        XCTAssertFalse(center.canUseVoice)
        XCTAssertEqual(center.blockingVoiceCapability, .speechRecognition)

        probe.grant(.speechRecognition)
        center.refresh()
        XCTAssertTrue(center.canUseVoice)
        XCTAssertNil(center.blockingVoiceCapability)
    }

    func testRequestingUpdatesState() async {
        let probe = FakePermissionProbe(states: [.microphone: .notDetermined])
        let center = PermissionCenter(probe: probe, observeActivation: false)

        let result = await center.request(.microphone)
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(center.state(of: .microphone), .granted)
        XCTAssertEqual(probe.requested, [.microphone])
    }

    func testDeniedRequestIsReportedAsDenied() async {
        let probe = FakePermissionProbe(states: [.microphone: .notDetermined])
        probe.requestResults[.microphone] = .denied
        let center = PermissionCenter(probe: probe, observeActivation: false)

        let result = await center.request(.microphone)
        XCTAssertEqual(result, .denied)
        XCTAssertFalse(center.canUseVoice)
    }

    func testRevocationIsReportedOnRefresh() {
        let probe = FakePermissionProbe(states: [.screenRecording: .granted])
        let center = PermissionCenter(probe: probe, observeActivation: false)

        var revoked: [PermissionCapability] = []
        center.onRevocation { revoked.append($0) }

        probe.revoke(.screenRecording)
        center.refresh()

        XCTAssertEqual(revoked, [.screenRecording])
        XCTAssertFalse(center.canReadScreen)
    }

    func testRevocationIsReportedOnlyOnce() {
        let probe = FakePermissionProbe(states: [.microphone: .granted])
        let center = PermissionCenter(probe: probe, observeActivation: false)
        var revoked: [PermissionCapability] = []
        center.onRevocation { revoked.append($0) }

        probe.revoke(.microphone)
        center.refresh()
        center.refresh()

        XCTAssertEqual(revoked, [.microphone])
    }

    func testGrantingSomethingNewIsNotARevocation() {
        let probe = FakePermissionProbe(states: [:])
        let center = PermissionCenter(probe: probe, observeActivation: false)
        var revoked: [PermissionCapability] = []
        center.onRevocation { revoked.append($0) }

        probe.grant(.microphone)
        center.refresh()
        XCTAssertTrue(revoked.isEmpty)
    }

    func testEveryCapabilityMapsToADistinctError() {
        let errors = PermissionCapability.allCases.map(\.missingError)
        XCTAssertEqual(Set(errors.map { $0.errorDescription ?? "" }).count, errors.count)
        for error in errors {
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    func testEveryCapabilityHasSettingsDeepLinkAndRationale() {
        for capability in PermissionCapability.allCases {
            XCTAssertNotNil(capability.settingsURL, "\(capability) has no System Settings link")
            XCTAssertFalse(capability.rationale.isEmpty)
            XCTAssertFalse(capability.featureName.isEmpty)
        }
    }

    func testOnlyScreenRecordingNeedsARelaunch() {
        XCTAssertTrue(PermissionCapability.screenRecording.needsRelaunchAfterGranting)
        for capability in PermissionCapability.allCases where capability != .screenRecording {
            XCTAssertFalse(capability.needsRelaunchAfterGranting)
        }
    }
}
