import Foundation

/// Writes to the system clipboard.
public protocol ClipboardWriting: Sendable {
    /// Returns the number of characters written.
    func write(_ text: String) throws -> Int
}

/// Opens a URL in the user's default browser.
public protocol URLOpening: Sendable {
    func open(_ url: URL) throws
}

/// Saves a note somewhere durable.
public protocol NoteWriting: Sendable {
    /// Returns a user-facing description of where it landed.
    func writeNote(title: String, body: String) throws -> String
}

/// A rectangle in global screen coordinates, in points with the origin at the
/// top left of the primary display. Declared without CoreGraphics so that
/// `ScreenMateCore` stays framework-free.
public struct ScreenRegion: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isUsable: Bool { width >= 8 && height >= 8 }
}

/// Captures the screen. Declared here so `ScreenMateCore` can express a
/// capture-backed tool without importing ScreenCaptureKit.
public protocol ScreenCapturing: Sendable {
    /// Whether macOS has granted Screen Recording access right now.
    func isAuthorized() async -> Bool
    /// Captures according to `scope`, honouring the sensitive-app guard.
    /// `region` is required when `scope` is `.selectedRegion` and ignored otherwise.
    func capture(scope: ScreenCaptureScope, region: ScreenRegion?) async throws -> ScreenContext
}

public extension ScreenCapturing {
    func capture(scope: ScreenCaptureScope) async throws -> ScreenContext {
        try await capture(scope: scope, region: nil)
    }
}

// MARK: - No-op implementations
//
// Used in tests, and in the app wherever a capability is switched off, so the
// call sites never branch on `nil`.

public struct NoopClipboardWriter: ClipboardWriting {
    public init() {}
    public func write(_ text: String) throws -> Int { text.count }
}

public struct NoopURLOpener: URLOpening {
    public init() {}
    public func open(_ url: URL) throws {}
}

public struct NoopNoteWriter: NoteWriting {
    public init() {}
    public func writeNote(title: String, body: String) throws -> String { "nowhere (no-op writer)" }
}
