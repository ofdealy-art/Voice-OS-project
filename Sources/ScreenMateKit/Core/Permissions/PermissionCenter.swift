import AppKit
import AVFoundation
import Combine
import CoreGraphics
import ScreenMateCore
import Speech

public enum PermissionCapability: String, CaseIterable, Sendable, Identifiable {
    case microphone
    case speechRecognition
    case screenRecording
    case accessibility

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    /// Shown in onboarding and in Settings › Privacy, in the user's terms.
    public var rationale: String {
        switch self {
        case .microphone:
            return "So you can talk to ScreenMate instead of typing. The microphone opens only while you hold the voice button or its shortcut, and closes the moment you let go."
        case .speechRecognition:
            return "To turn your recording into text. macOS does this on-device where your Mac supports it; otherwise Apple's speech service transcribes it."
        case .screenRecording:
            return "So ScreenMate can look at what you point it at. Nothing is captured until you ask for it, and you see the picture before it is sent anywhere."
        case .accessibility:
            return "Optional. Lets ScreenMate read the title of the window you are asking about, so it can label the capture and skip windows that look like they hold credentials."
        }
    }

    /// Which part of ScreenMate stops working without it. Nothing here is
    /// mandatory: typing to a text model works with no permissions at all.
    public var featureName: String {
        switch self {
        case .microphone, .speechRecognition: return "Voice input"
        case .screenRecording: return "Screen awareness"
        case .accessibility: return "Window titles and the sensitive-app guard"
        }
    }

    /// True when macOS requires the app to be relaunched after granting.
    public var needsRelaunchAfterGranting: Bool {
        self == .screenRecording
    }

    /// Deep link into the right System Settings pane.
    public var settingsURL: URL? {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// The error to raise when this is missing at the moment it is needed.
    public var missingError: AppError {
        switch self {
        case .microphone: return .microphonePermissionDenied
        case .speechRecognition: return .speechRecognitionPermissionDenied
        case .screenRecording: return .screenRecordingPermissionDenied
        case .accessibility: return .accessibilityPermissionDenied
        }
    }
}

public enum PermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    /// Blocked by a configuration profile or parental controls; asking will not help.
    case restricted

    public var isGranted: Bool { self == .granted }
    public var canBeRequested: Bool { self == .notDetermined }

    public var displayName: String {
        switch self {
        case .notDetermined: return "Not asked yet"
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .restricted: return "Blocked by this Mac's settings"
        }
    }
}

/// The seam over TCC. `SystemPermissionProbe` is the real one; tests inject a fake.
public protocol PermissionProbing: Sendable {
    func state(of capability: PermissionCapability) -> PermissionState
    func request(_ capability: PermissionCapability) async -> PermissionState
    func openSystemSettings(for capability: PermissionCapability)
}

public struct SystemPermissionProbe: PermissionProbing {
    public init() {}

    public func state(of capability: PermissionCapability) -> PermissionState {
        switch capability {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }

        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }

        case .screenRecording:
            // Preflight never prompts, so it is safe on every refresh.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied

        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        }
    }

    public func request(_ capability: PermissionCapability) async -> PermissionState {
        switch capability {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)

        case .speechRecognition:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }

        case .screenRecording:
            // Shows the system prompt the first time; afterwards it returns the
            // current answer immediately. macOS requires a relaunch before newly
            // granted access takes effect, which the UI tells the user.
            _ = await Task.detached { CGRequestScreenCaptureAccess() }.value

        case .accessibility:
            // No async API exists; this opens System Settings with a prompt.
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return state(of: capability)
    }

    public func openSystemSettings(for capability: PermissionCapability) {
        guard let url = capability.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Observable view of the app's permission state.
///
/// macOS gives no notification when the user changes a permission, so the center
/// re-reads on every app activation. That is also how a mid-session revocation is
/// noticed, which the app has to handle: a granted permission can vanish while a
/// recording or capture is in flight.
@MainActor
public final class PermissionCenter: ObservableObject {
    @Published public private(set) var states: [PermissionCapability: PermissionState] = [:]

    private let probe: any PermissionProbing
    private var lastKnownGranted: Set<PermissionCapability> = []
    private var revocationHandler: ((PermissionCapability) -> Void)?
    /// Holds the notification token. A separate object because a `@MainActor`
    /// class's `deinit` is non-isolated and may not touch isolated state.
    private let observerBox = NotificationObserverBox()

    public init(probe: any PermissionProbing = SystemPermissionProbe(), observeActivation: Bool = true) {
        self.probe = probe
        refresh()
        guard observeActivation else { return }
        observerBox.token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Called when something that was granted has since been turned off.
    public func onRevocation(_ handler: @escaping (PermissionCapability) -> Void) {
        revocationHandler = handler
    }

    public func refresh() {
        var updated: [PermissionCapability: PermissionState] = [:]
        for capability in PermissionCapability.allCases {
            updated[capability] = probe.state(of: capability)
        }
        states = updated

        let granted = Set(updated.filter { $0.value.isGranted }.keys)
        let revoked = lastKnownGranted.subtracting(granted)
        lastKnownGranted = granted
        for capability in revoked.sorted(by: { $0.rawValue < $1.rawValue }) {
            revocationHandler?(capability)
        }
    }

    public func state(of capability: PermissionCapability) -> PermissionState {
        states[capability] ?? .notDetermined
    }

    @discardableResult
    public func request(_ capability: PermissionCapability) async -> PermissionState {
        let result = await probe.request(capability)
        refresh()
        return result
    }

    public func openSystemSettings(for capability: PermissionCapability) {
        probe.openSystemSettings(for: capability)
    }

    public var canUseVoice: Bool {
        state(of: .microphone).isGranted && state(of: .speechRecognition).isGranted
    }

    public var canReadScreen: Bool {
        state(of: .screenRecording).isGranted
    }

    /// The first capability standing between the user and voice input, if any.
    public var blockingVoiceCapability: PermissionCapability? {
        if !state(of: .microphone).isGranted { return .microphone }
        if !state(of: .speechRecognition).isGranted { return .speechRecognition }
        return nil
    }
}

/// Removes a `NotificationCenter` block observer when its owner goes away.
///
/// Exists so `PermissionCenter` needs no `deinit` of its own: a global-actor
/// isolated class cannot reach its isolated properties from `deinit`.
final class NotificationObserverBox: @unchecked Sendable {
    var token: (any NSObjectProtocol)?

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
