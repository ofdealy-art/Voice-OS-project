import Foundation

public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case user
    case assistant
    case system
}

/// A screenshot or file the user attached to a message.
///
/// Note the deliberate absence of image bytes: attachments are persisted as
/// *metadata only*. The pixels live in `ScreenContext` for the lifetime of the
/// request and are then dropped, so saved conversations never contain pictures
/// of the user's screen. `ocrText` is stored only when the user has opted into
/// saving conversations and text extraction.
public struct MessageAttachment: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case fullScreen
        case display
        case region
        case window
        case droppedImage
        case droppedFile
    }

    public let id: UUID
    public let kind: Kind
    public let label: String
    public let mimeType: String
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Text extracted on-device by Vision, if OCR was enabled.
    public let extractedText: String?
    /// Human-readable provenance, e.g. "Safari — Built-in Retina Display".
    public let sourceDescription: String?
    /// Redaction findings the app removed or flagged before sending.
    public let redactionSummary: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        label: String,
        mimeType: String,
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        extractedText: String? = nil,
        sourceDescription: String? = nil,
        redactionSummary: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.extractedText = extractedText
        self.sourceDescription = sourceDescription
        self.redactionSummary = redactionSummary
    }
}

/// A web source the assistant used. Rendered as a footnote under the reply so
/// the user can tell model knowledge from retrieved fact.
public struct WebCitation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let url: URL
    public let snippet: String?
    public let retrievedAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, snippet: String? = nil, retrievedAt: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.retrievedAt = retrievedAt
    }
}

/// A record of a tool the assistant ran, shown inline in the transcript.
public struct ToolInvocationRecord: Identifiable, Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        case declinedByUser
        case awaitingConfirmation
    }

    public let id: UUID
    public let toolName: String
    public let summary: String
    public var outcome: Outcome
    public var detail: String?
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        toolName: String,
        summary: String,
        outcome: Outcome,
        detail: String? = nil,
        startedAt: Date
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.outcome = outcome
        self.detail = detail
        self.startedAt = startedAt
    }
}

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case typed
        case voice
        case model
        case system
    }

    public let id: UUID
    public let role: MessageRole
    public var text: String
    public let createdAt: Date
    public let source: Source
    public var attachments: [MessageAttachment]
    public var citations: [WebCitation]
    public var toolInvocations: [ToolInvocationRecord]
    /// Set while tokens are still arriving, so the UI can show a caret.
    public var isStreaming: Bool
    /// Populated instead of `text` when the turn failed.
    public var failure: MessageFailure?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        createdAt: Date = Date(),
        source: Source,
        attachments: [MessageAttachment] = [],
        citations: [WebCitation] = [],
        toolInvocations: [ToolInvocationRecord] = [],
        isStreaming: Bool = false,
        failure: MessageFailure? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.source = source
        self.attachments = attachments
        self.citations = citations
        self.toolInvocations = toolInvocations
        self.isStreaming = isStreaming
        self.failure = failure
    }

    public var isEmptyPlaceholder: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
            && toolInvocations.isEmpty
            && failure == nil
    }
}

/// A persisted, presentation-ready snapshot of an `AppError`.
///
/// `AppError` itself is not `Codable` (it carries associated values that will
/// keep changing); storing the rendered strings keeps old transcripts readable
/// across app versions.
public struct MessageFailure: Codable, Sendable, Equatable {
    public let message: String
    public let nextStep: String?
    public let isRetryable: Bool

    public init(message: String, nextStep: String?, isRetryable: Bool) {
        self.message = message
        self.nextStep = nextStep
        self.isRetryable = isRetryable
    }

    public init(_ error: AppError) {
        self.message = error.errorDescription ?? "Something went wrong."
        self.nextStep = error.recoverySuggestion
        self.isRetryable = error.isRetryable
    }
}
