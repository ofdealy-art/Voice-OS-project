import AppKit
import Foundation

/// What ScreenMate knows about the window it is about to capture.
public struct FrontWindowInfo: Sendable, Equatable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let title: String?
    /// ScreenCaptureKit window id, when it could be matched.
    public let windowID: CGWindowID?
    /// Display the window is mostly on, so multi-monitor captures pick the right one.
    public let displayID: CGDirectDisplayID?

    public init(
        appName: String?,
        bundleIdentifier: String?,
        title: String?,
        windowID: CGWindowID?,
        displayID: CGDirectDisplayID?
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.windowID = windowID
        self.displayID = displayID
    }

    /// "Safari — Built-in Retina Display"
    public func sourceDescription(displayName: String?) -> String {
        let app = appName ?? "Unknown app"
        guard let displayName, !displayName.isEmpty else { return app }
        return "\(app) — \(displayName)"
    }
}

/// Identifies the frontmost window, excluding ScreenMate's own panel.
///
/// Window *titles* come from `CGWindowListCopyWindowInfo`, which needs Screen
/// Recording access; without it, the app name is still available from
/// `NSWorkspace` and the capture is simply labelled less precisely. The
/// sensitive-app guard therefore still works by bundle identifier even when
/// titles are unavailable.
@MainActor
public struct WindowInspector {
    public init() {}

    public func frontWindow() -> FrontWindowInfo {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        // If ScreenMate itself is frontmost (the user clicked the panel), report
        // the app behind it instead — that is what they are asking about.
        let targetApp: NSRunningApplication? = {
            if frontApp?.processIdentifier == ownPID {
                return NSWorkspace.shared.runningApplications.first {
                    $0.activationPolicy == .regular
                        && $0.processIdentifier != ownPID
                        && !$0.isHidden
                }
            }
            return frontApp
        }()

        guard let info = topmostWindowInfo(excludingPID: ownPID, preferredPID: targetApp?.processIdentifier) else {
            return FrontWindowInfo(
                appName: targetApp?.localizedName,
                bundleIdentifier: targetApp?.bundleIdentifier,
                title: nil,
                windowID: nil,
                displayID: nil
            )
        }
        return info
    }

    private func topmostWindowInfo(
        excludingPID ownPID: pid_t,
        preferredPID: pid_t?
    ) -> FrontWindowInfo? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue } // normal windows only
            if let preferredPID, pid != preferredPID { continue }

            let bounds = (window[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            let app = NSRunningApplication(processIdentifier: pid)

            return FrontWindowInfo(
                appName: (window[kCGWindowOwnerName as String] as? String) ?? app?.localizedName,
                bundleIdentifier: app?.bundleIdentifier,
                title: window[kCGWindowName as String] as? String,
                windowID: (window[kCGWindowNumber as String] as? UInt32).map { CGWindowID($0) },
                displayID: bounds.flatMap(Self.displayID(containing:))
            )
        }
        return nil
    }

    /// The display that holds most of `rect`, so a window straddling two screens
    /// is captured from the one the user is mostly looking at.
    public static func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let overlap = screen.frameInCoreGraphicsCoordinates.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area {
                best = (id, area)
            }
        }
        return best?.id ?? NSScreen.main?.displayID
    }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// AppKit's origin is bottom-left of the primary screen; CoreGraphics and
    /// ScreenCaptureKit use top-left. Region selection has to convert between
    /// them or captures land on the wrong part of a multi-monitor desktop.
    var frameInCoreGraphicsCoordinates: CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        let flippedY = primary.frame.maxY - frame.maxY
        return CGRect(x: frame.minX, y: flippedY, width: frame.width, height: frame.height)
    }

    var friendlyName: String { localizedName }
}
