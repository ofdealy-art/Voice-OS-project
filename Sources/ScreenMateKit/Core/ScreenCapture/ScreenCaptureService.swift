import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ScreenMateCore

/// Reads the screen through ScreenCaptureKit.
///
/// Three rules are enforced here rather than trusted to callers:
/// 1. Nothing is captured without Screen Recording access.
/// 2. Nothing is captured from a window the sensitive-app guard blocks.
/// 3. Text found in a capture is run through the redactor before it is attached.
///
/// `SCScreenshotManager` is macOS 14+. On macOS 13 the service falls back to
/// `CGDisplayCreateImage` / `CGWindowListCreateImage`, which need the same
/// permission and produce the same result for a still capture.
public actor ScreenCaptureService: ScreenCapturing {
    private let encoder: CapturedImageEncoder
    private let ocr: OCRService
    private let redactor: SensitiveTextRedactor
    private let policy: SensitiveAppPolicy
    /// Read at capture time so a change in Settings takes effect immediately.
    private let settingsProvider: @Sendable () -> AppSettings

    public init(
        encoder: CapturedImageEncoder = CapturedImageEncoder(),
        ocr: OCRService = OCRService(),
        redactor: SensitiveTextRedactor = SensitiveTextRedactor(),
        policy: SensitiveAppPolicy = SensitiveAppPolicy(),
        settingsProvider: @escaping @Sendable () -> AppSettings
    ) {
        self.encoder = encoder
        self.ocr = ocr
        self.redactor = redactor
        self.policy = policy
        self.settingsProvider = settingsProvider
    }

    /// Raised when the guard refuses a window, so the UI can show the reason
    /// rather than a generic failure.
    public struct BlockedBySensitiveApp: Error, Sendable {
        public let reason: String
    }

    public func isAuthorized() async -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func capture(scope: ScreenCaptureScope, region: ScreenRegion?) async throws -> ScreenContext {
        let settings = settingsProvider()

        guard settings.screenAwarenessEnabled else {
            // Belt and braces: the state machine already refuses, but the actor
            // must not be capturable by any other path either.
            throw AppError.screenAwarenessDisabled
        }
        guard await isAuthorized() else {
            throw AppError.screenRecordingPermissionDenied
        }

        let window = await MainActor.run { WindowInspector().frontWindow() }

        let decision = policy.evaluate(
            bundleIdentifier: window.bundleIdentifier,
            windowTitle: window.title,
            appName: window.appName,
            isEnabled: settings.skipCaptureForSensitiveApps
        )
        if decision.isBlocked {
            throw BlockedBySensitiveApp(reason: decision.reason ?? "That window is not captured.")
        }

        let captured: (image: CGImage, kind: MessageAttachment.Kind, description: String, scale: Double)
        switch scope {
        case .activeWindow:
            captured = try await captureFrontWindow(window)
        case .activeDisplay:
            captured = try await captureDisplay(containing: window)
        case .selectedRegion:
            guard let region, region.isUsable else {
                throw AppError.screenCaptureFailed(detail: "no area was selected")
            }
            captured = try await captureRegion(region)
        }

        let encoded = try encoder.encode(captured.image)

        var extractedText: String?
        var findings: [RedactionFinding] = []
        if settings.runOCROnCaptures {
            let recognised = await ocr.recognizeText(in: captured.image)
            if !recognised.isEmpty {
                if settings.redactSensitiveContent {
                    let result = redactor.redact(recognised)
                    extractedText = result.text
                    findings = result.findings
                } else {
                    extractedText = recognised
                }
            }
        }

        return ScreenContext(
            kind: captured.kind,
            imageData: encoded.data,
            mimeType: encoded.mimeType,
            pixelWidth: encoded.pixelWidth,
            pixelHeight: encoded.pixelHeight,
            backingScaleFactor: captured.scale,
            sourceDescription: captured.description,
            sourceBundleIdentifier: window.bundleIdentifier,
            extractedText: extractedText,
            redactionFindings: findings
        )
    }

    // MARK: - Window

    private func captureFrontWindow(
        _ window: FrontWindowInfo
    ) async throws -> (CGImage, MessageAttachment.Kind, String, Double) {
        let displayName = await MainActor.run { Self.displayName(for: window.displayID) }
        let description = window.sourceDescription(displayName: displayName)
        let scale = await MainActor.run { Self.backingScale(for: window.displayID) }

        if #available(macOS 14.0, *) {
            if let windowID = window.windowID,
               let scWindow = try? await Self.shareableWindow(id: windowID) {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let configuration = SCStreamConfiguration()
                configuration.width = Int(scWindow.frame.width * CGFloat(scale))
                configuration.height = Int(scWindow.frame.height * CGFloat(scale))
                configuration.showsCursor = false
                configuration.captureResolution = .best
                do {
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    )
                    return (image, .window, description, scale)
                } catch {
                    // Fall through to the display capture below: a window can
                    // disappear between listing and capturing.
                }
            }
        } else if let windowID = window.windowID {
            if let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                return (image, .window, description, scale)
            }
        }

        // No usable window: give the user the display instead of nothing, and say so.
        let display = try await captureDisplay(containing: window)
        return (display.0, display.1, display.2, display.3)
    }

    @available(macOS 14.0, *)
    private static func shareableWindow(id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        return content.windows.first { $0.windowID == id }
    }

    // MARK: - Display

    private func captureDisplay(
        containing window: FrontWindowInfo
    ) async throws -> (CGImage, MessageAttachment.Kind, String, Double) {
        let fallbackDisplay = await MainActor.run { NSScreen.main?.displayID }
        guard let displayID = window.displayID ?? fallbackDisplay else {
            throw AppError.noCapturableDisplay
        }

        let displayName = await MainActor.run { Self.displayName(for: displayID) } ?? "Display"
        let scale = await MainActor.run { Self.backingScale(for: displayID) }
        let image = try await captureWholeDisplay(displayID, scale: scale)
        return (image, .display, displayName, scale)
    }

    private func captureWholeDisplay(_ displayID: CGDirectDisplayID, scale: Double) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw AppError.noCapturableDisplay
            }
            // Exclude ScreenMate's own windows so the assistant does not
            // photograph itself sitting on top of what the user asked about.
            let ownWindows = content.windows.filter {
                $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(Double(display.width) * scale)
            configuration.height = Int(Double(display.height) * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            do {
                return try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            } catch {
                throw AppError.screenCaptureFailed(detail: error.localizedDescription)
            }
        }

        guard let image = CGDisplayCreateImage(displayID) else {
            throw AppError.screenCaptureFailed(detail: "the display could not be read")
        }
        return image
    }

    // MARK: - Region

    /// `region` arrives in CoreGraphics global coordinates (origin top-left of the
    /// primary display). The display it falls on is captured whole, then cropped
    /// in that display's pixel space — which is what makes this correct on Retina
    /// screens and across monitors with different scale factors.
    private func captureRegion(
        _ region: ScreenRegion
    ) async throws -> (CGImage, MessageAttachment.Kind, String, Double) {
        let rect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        let resolvedDisplay = await MainActor.run { WindowInspector.displayID(containing: rect) }
        guard let displayID = resolvedDisplay else {
            throw AppError.noCapturableDisplay
        }

        let (displayOrigin, scale, displayName) = await MainActor.run { () -> (CGPoint, Double, String) in
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                return (.zero, 2, "Display")
            }
            let frame = screen.frameInCoreGraphicsCoordinates
            return (frame.origin, Double(screen.backingScaleFactor), screen.friendlyName)
        }

        let full = try await captureWholeDisplay(displayID, scale: scale)

        // Convert from global points to this display's pixels.
        let pixelScale = CGFloat(scale)
        let local = CGRect(
            x: (rect.minX - displayOrigin.x) * pixelScale,
            y: (rect.minY - displayOrigin.y) * pixelScale,
            width: rect.width * pixelScale,
            height: rect.height * pixelScale
        )
        let cropped = try encoder.crop(full, to: local)
        return (cropped, .region, "Selected region — \(displayName)", scale)
    }

    // MARK: - Display metadata

    @MainActor
    private static func displayName(for displayID: CGDirectDisplayID?) -> String? {
        guard let displayID else { return NSScreen.main?.friendlyName }
        return NSScreen.screens.first { $0.displayID == displayID }?.friendlyName
    }

    @MainActor
    private static func backingScale(for displayID: CGDirectDisplayID?) -> Double {
        if let displayID, let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            return Double(screen.backingScaleFactor)
        }
        return NSScreen.main.map { Double($0.backingScaleFactor) } ?? 2
    }
}
