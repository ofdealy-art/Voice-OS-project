import Foundation

public enum ScreenCaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case permissionDenied(AppError)
    /// The drag-select overlay is up.
    case selectingRegion
    case capturing(ScreenCaptureScope)
    /// Captured and waiting for the user to approve or discard it.
    case previewing(ScreenContext)
    /// Approved and attached to the composer, ready to send.
    case attached(ScreenContext)
    case blocked(reason: String)
    case failed(AppError)

    public var pendingContext: ScreenContext? {
        switch self {
        case .previewing(let context), .attached(let context): return context
        default: return nil
        }
    }

    /// Drives the on-screen "reading your screen" indicator. True only while
    /// pixels are genuinely being read.
    public var isCapturing: Bool {
        switch self {
        case .capturing, .selectingRegion: return true
        default: return false
        }
    }
}

public enum ScreenCaptureEvent: Equatable, Sendable {
    case captureRequested(scope: ScreenCaptureScope, hasPermission: Bool, awarenessEnabled: Bool)
    case permissionGranted(scope: ScreenCaptureScope)
    case permissionRefused(AppError)
    case regionSelected
    case captured(ScreenContext)
    case blockedBySensitiveApp(reason: String)
    case captureFailed(AppError)
    /// User approved the preview.
    case approved
    /// User pressed Escape / the discard button, at any stage.
    case cancelled
    /// The turn finished (or failed) and the attachment must be released.
    case consumed
}

public enum ScreenCaptureEffect: Equatable, Sendable {
    case requestPermission
    case showRegionSelector
    case performCapture(ScreenCaptureScope)
    /// Free the pixel buffer now.
    case discardImage
    case announce(String)
    /// Ask the user to switch screen awareness on; capture does not proceed.
    case promptToEnableScreenAwareness
}

/// The capture lifecycle, including the rule that nothing is ever captured while
/// screen awareness is off and nothing is ever sent without a preview.
public struct ScreenCaptureMachine: Sendable {
    public private(set) var state: ScreenCaptureState = .idle
    /// Mirrors `AppSettings.alwaysPreviewBeforeSending`.
    public var requiresPreview: Bool

    public init(requiresPreview: Bool = true) {
        self.requiresPreview = requiresPreview
    }

    @discardableResult
    public mutating func handle(_ event: ScreenCaptureEvent) -> [ScreenCaptureEffect] {
        switch (state, event) {

        case (_, .captureRequested(let scope, let hasPermission, let awarenessEnabled)):
            guard awarenessEnabled else {
                // Hard stop: the app does not capture, even once, to ask.
                state = .idle
                return [.promptToEnableScreenAwareness]
            }
            guard hasPermission else {
                state = .requestingPermission
                return [.requestPermission]
            }
            if scope == .selectedRegion {
                state = .selectingRegion
                return [.showRegionSelector, .announce("Drag to select the area to analyse")]
            }
            state = .capturing(scope)
            return [.performCapture(scope), .announce("Reading your screen")]

        case (.requestingPermission, .permissionGranted(let scope)):
            if scope == .selectedRegion {
                state = .selectingRegion
                return [.showRegionSelector]
            }
            state = .capturing(scope)
            return [.performCapture(scope), .announce("Reading your screen")]

        case (.requestingPermission, .permissionRefused(let error)),
             (.capturing, .permissionRefused(let error)),
             (.selectingRegion, .permissionRefused(let error)):
            state = .permissionDenied(error)
            return [.discardImage, .announce(error.errorDescription ?? "Screen Recording is unavailable")]

        case (.selectingRegion, .regionSelected):
            state = .capturing(.selectedRegion)
            return [.performCapture(.selectedRegion)]

        case (.capturing, .captured(let context)):
            if requiresPreview {
                state = .previewing(context)
                return [.announce("Captured. Check the preview, then send.")]
            }
            state = .attached(context)
            return [.announce("Captured and attached")]

        case (.capturing, .blockedBySensitiveApp(let reason)),
             (.selectingRegion, .blockedBySensitiveApp(let reason)):
            state = .blocked(reason: reason)
            return [.discardImage, .announce(reason)]

        case (.capturing, .captureFailed(let error)),
             (.selectingRegion, .captureFailed(let error)):
            state = .failed(error)
            return [.discardImage, .announce(error.errorDescription ?? "Screen capture failed")]

        case (.previewing(let context), .approved):
            state = .attached(context)
            return [.announce("Attached to your next message")]

        case (.selectingRegion, .cancelled),
             (.capturing, .cancelled),
             (.requestingPermission, .cancelled):
            state = .idle
            return [.discardImage, .announce("Screen capture cancelled")]

        case (.previewing, .cancelled), (.attached, .cancelled):
            state = .idle
            return [.discardImage, .announce("Screen capture discarded")]

        case (.attached, .consumed), (.previewing, .consumed):
            state = .idle
            return [.discardImage]

        // Clearing a terminal state returns to idle without side effects.
        case (.failed, .cancelled), (.blocked, .cancelled), (.permissionDenied, .cancelled):
            state = .idle
            return []

        case (.idle, .consumed), (.failed, .consumed), (.blocked, .consumed), (.permissionDenied, .consumed):
            state = .idle
            return [.discardImage]

        default:
            return []
        }
    }

    /// Screen awareness was switched off. Anything held must go immediately.
    public mutating func screenAwarenessDisabled() -> [ScreenCaptureEffect] {
        let hadContext = state.pendingContext != nil
        state = .idle
        return hadContext
            ? [.discardImage, .announce("Screen awareness off — the pending capture was discarded")]
            : [.discardImage]
    }
}
