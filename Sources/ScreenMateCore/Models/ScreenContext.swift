import Foundation

/// A captured image plus everything the app knows about where it came from.
///
/// Held in memory only. `imageData` is dropped as soon as a request finishes
/// (see `ScreenContextBox.discard()`); nothing here is written to disk.
public struct ScreenContext: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: MessageAttachment.Kind
    /// PNG or JPEG bytes, already downscaled to the configured budget.
    public let imageData: Data
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Backing scale of the display the capture came from (2.0 on Retina).
    public let backingScaleFactor: Double
    public let capturedAt: Date
    /// e.g. "Safari — Studio Display"
    public let sourceDescription: String
    /// Bundle identifier of the frontmost app at capture time, when known.
    public let sourceBundleIdentifier: String?
    /// On-device OCR output, if enabled.
    public let extractedText: String?
    /// What the redactor found in `extractedText`.
    public let redactionFindings: [RedactionFinding]

    public init(
        id: UUID = UUID(),
        kind: MessageAttachment.Kind,
        imageData: Data,
        mimeType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        backingScaleFactor: Double,
        capturedAt: Date = Date(),
        sourceDescription: String,
        sourceBundleIdentifier: String? = nil,
        extractedText: String? = nil,
        redactionFindings: [RedactionFinding] = []
    ) {
        self.id = id
        self.kind = kind
        self.imageData = imageData
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.backingScaleFactor = backingScaleFactor
        self.capturedAt = capturedAt
        self.sourceDescription = sourceDescription
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.extractedText = extractedText
        self.redactionFindings = redactionFindings
    }

    public var byteCount: Int { imageData.count }

    /// Metadata-only projection that is safe to persist in a transcript.
    public func attachment(includeExtractedText: Bool) -> MessageAttachment {
        MessageAttachment(
            id: id,
            kind: kind,
            label: label,
            mimeType: mimeType,
            byteCount: byteCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            extractedText: includeExtractedText ? extractedText : nil,
            sourceDescription: sourceDescription,
            redactionSummary: redactionFindings.isEmpty ? nil : RedactionFinding.summary(redactionFindings)
        )
    }

    public var label: String {
        switch kind {
        case .fullScreen: return "All displays"
        case .display: return "Display"
        case .region: return "Selected region"
        case .window: return "Front window"
        case .droppedImage: return "Dropped image"
        case .droppedFile: return "Dropped file"
        }
    }
}

/// Holds the pending screen context for one turn and guarantees it is cleared.
///
/// A reference type on purpose: the view model shows it, the request builder
/// reads it, and exactly one place is responsible for zeroing it out.
public final class ScreenContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ScreenContext?

    public init(_ context: ScreenContext? = nil) {
        self.storage = context
    }

    public var value: ScreenContext? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func set(_ context: ScreenContext?) {
        lock.lock()
        storage = context
        lock.unlock()
    }

    /// Drops the pixel buffer. Called on send completion, on cancel, when
    /// screen awareness is switched off, and on app termination.
    public func discard() {
        lock.lock()
        storage = nil
        lock.unlock()
    }
}
