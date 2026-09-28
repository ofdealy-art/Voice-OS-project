import AppKit
import Combine
import Foundation
import ScreenMateCore

/// Drives screen capture: owns the state machine, the capture service and the
/// region-selection overlay.
///
/// The decisions — may we capture, must we preview, when is the image released —
/// all live in `ScreenCaptureMachine`. This class performs its effects and holds
/// the pixel buffer in a `ScreenContextBox` that it is responsible for emptying.
@MainActor
public final class ScreenAwarenessController: ObservableObject {
    @Published public private(set) var state: ScreenCaptureState = .idle
    /// True while the overlay is up or a capture is being taken. Drives the
    /// visible "reading your screen" indicator.
    @Published public private(set) var isReadingScreen = false

    public var onAnnouncement: ((String) -> Void)?
    /// Raised when the user asks for a capture while screen awareness is off.
    public var onNeedsScreenAwareness: (() -> Void)?
    public var onError: ((AppError) -> Void)?
    /// Called on every transition, so the assistant's activity indicator matches.
    public var onStateChange: ((ScreenCaptureState) -> Void)?

    private var machine: ScreenCaptureMachine
    private let capturer: any ScreenCapturing
    private let permissions: PermissionCenter
    private let regionSelector: RegionSelectionController
    private let settingsProvider: () -> AppSettings
    /// The single owner of pending capture pixels.
    private let contextBox = ScreenContextBox()
    private var captureTask: Task<Void, Never>?
    /// Set by the region selector, consumed by the next capture.
    private var pendingRegion: ScreenRegion?

    public init(
        capturer: any ScreenCapturing,
        permissions: PermissionCenter,
        regionSelector: RegionSelectionController = RegionSelectionController(),
        settingsProvider: @escaping () -> AppSettings
    ) {
        self.capturer = capturer
        self.permissions = permissions
        self.regionSelector = regionSelector
        self.settingsProvider = settingsProvider
        self.machine = ScreenCaptureMachine(requiresPreview: settingsProvider().alwaysPreviewBeforeSending)
    }

    /// The capture waiting to be sent, if the user has approved one.
    public var attachedContext: ScreenContext? {
        if case .attached(let context) = state { return context }
        return nil
    }

    /// The capture awaiting approval, shown in the preview sheet.
    public var previewContext: ScreenContext? {
        if case .previewing(let context) = state { return context }
        return nil
    }

    // MARK: - Intent

    public func capture(scope: ScreenCaptureScope? = nil) {
        let settings = settingsProvider()
        machine.requiresPreview = settings.alwaysPreviewBeforeSending
        apply(machine.handle(.captureRequested(
            scope: scope ?? settings.defaultCaptureScope,
            hasPermission: permissions.canReadScreen,
            awarenessEnabled: settings.screenAwarenessEnabled
        )))
    }

    public func approvePreview() {
        apply(machine.handle(.approved))
    }

    public func discard() {
        captureTask?.cancel()
        captureTask = nil
        regionSelector.dismiss()
        apply(machine.handle(.cancelled))
    }

    /// Called after a turn completes, successfully or not.
    public func releaseAttachment() {
        apply(machine.handle(.consumed))
    }

    /// Called when the Settings toggle is switched off.
    public func screenAwarenessDisabled() {
        captureTask?.cancel()
        captureTask = nil
        regionSelector.dismiss()
        apply(machine.screenAwarenessDisabled())
    }

    /// Called when macOS revokes Screen Recording access mid-session.
    public func permissionRevoked() {
        apply(machine.handle(.permissionRefused(
            .permissionRevokedWhileRunning(capability: "Screen Recording")
        )))
    }

    /// Accepts a capture the model requested through `capture_screen`, which has
    /// already been through the confirmation gate.
    public func adopt(_ context: ScreenContext) {
        contextBox.set(context)
        machine.requiresPreview = false
        apply(machine.handle(.captureRequested(
            scope: .activeWindow,
            hasPermission: true,
            awarenessEnabled: settingsProvider().screenAwarenessEnabled
        )))
        apply(machine.handle(.captured(context)))
        machine.requiresPreview = settingsProvider().alwaysPreviewBeforeSending
    }

    // MARK: - Effects

    private func apply(_ effects: [ScreenCaptureEffect]) {
        publish()

        for effect in effects {
            switch effect {
            case .requestPermission:
                requestPermission()
            case .showRegionSelector:
                showRegionSelector()
            case .performCapture(let scope):
                performCapture(scope: scope, region: pendingRegion)
            case .discardImage:
                contextBox.discard()
                pendingRegion = nil
            case .announce(let message):
                onAnnouncement?(message)
            case .promptToEnableScreenAwareness:
                onNeedsScreenAwareness?()
            }
        }
        publish()
        if case .failed(let error) = machine.state { onError?(error) }
    }

    private func publish() {
        isReadingScreen = machine.state.isCapturing
        guard state != machine.state else { return }
        state = machine.state
        onStateChange?(state)
    }

    private func requestPermission() {
        Task { @MainActor in
            let result = await permissions.request(.screenRecording)
            guard result.isGranted else {
                apply(machine.handle(.permissionRefused(.screenRecordingPermissionDenied)))
                return
            }
            apply(machine.handle(.permissionGranted(scope: settingsProvider().defaultCaptureScope)))
        }
    }

    private func showRegionSelector() {
        regionSelector.present { [weak self] region in
            guard let self else { return }
            guard let region else {
                self.apply(self.machine.handle(.cancelled))
                return
            }
            self.pendingRegion = region
            self.apply(self.machine.handle(.regionSelected))
        }
    }

    private func performCapture(scope: ScreenCaptureScope, region: ScreenRegion?) {
        captureTask?.cancel()
        let capturer = self.capturer
        captureTask = Task { @MainActor [weak self] in
            do {
                let context = try await capturer.capture(scope: scope, region: region)
                guard let self, !Task.isCancelled else { return }
                self.contextBox.set(context)
                self.apply(self.machine.handle(.captured(context)))
            } catch let blocked as ScreenCaptureService.BlockedBySensitiveApp {
                guard let self else { return }
                self.apply(self.machine.handle(.blockedBySensitiveApp(reason: blocked.reason)))
            } catch {
                guard let self else { return }
                self.apply(self.machine.handle(.captureFailed(AppError.wrapping(error))))
            }
        }
    }
}
