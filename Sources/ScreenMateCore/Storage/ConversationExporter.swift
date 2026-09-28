import Foundation

/// Renders a transcript for export.
///
/// Markdown is the default because it opens anywhere; JSON is offered so a user
/// can take their data somewhere else. Neither contains image bytes, because the
/// app never keeps them.
public struct ConversationExporter: Sendable {
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        case markdown
        case json
        case plainText

        public var id: String { rawValue }

        public var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .json: return "json"
            case .plainText: return "txt"
            }
        }

        public var displayName: String {
            switch self {
            case .markdown: return "Markdown"
            case .json: return "JSON"
            case .plainText: return "Plain text"
            }
        }
    }

    public init() {}

    public func export(_ conversation: Conversation, as format: Format) throws -> Data {
        let string: String
        switch format {
        case .markdown: string = markdown(conversation)
        case .plainText: string = plainText(conversation)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            do {
                return try encoder.encode(conversation)
            } catch {
                throw AppError.storageFailure(detail: "the transcript could not be encoded")
            }
        }
        guard let data = string.data(using: .utf8) else {
            throw AppError.storageFailure(detail: "the transcript could not be encoded")
        }
        return data
    }

    public func suggestedFilename(for conversation: Conversation, format: Format) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let safeTitle = conversation.title
            .replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let stem = safeTitle.isEmpty ? "conversation" : String(safeTitle.prefix(48))
        return "ScreenMate-\(stem)-\(formatter.string(from: conversation.createdAt)).\(format.fileExtension)"
    }

    func markdown(_ conversation: Conversation) -> String {
        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .short

        var lines = ["# \(conversation.title)", ""]
        lines.append("Exported from ScreenMate on \(stamp.string(from: Date())).")
        if let provider = conversation.providerID {
            let model = conversation.modelID.map { " · \($0)" } ?? ""
            lines.append("Provider: \(provider)\(model)")
        }
        lines.append("")

        for message in conversation.messages {
            let speaker: String
            switch message.role {
            case .user: speaker = message.source == .voice ? "You (spoken)" : "You"
            case .assistant: speaker = "ScreenMate"
            case .system: speaker = "System"
            }
            lines.append("## \(speaker) — \(stamp.string(from: message.createdAt))")
            lines.append("")

            for attachment in message.attachments {
                var note = "*Attached: \(attachment.label)"
                if let source = attachment.sourceDescription { note += " (\(source))" }
                note += ", \(attachment.pixelWidth)×\(attachment.pixelHeight). The image itself was not saved.*"
                lines.append(note)
                if let redaction = attachment.redactionSummary {
                    lines.append("*\(redaction)*")
                }
                lines.append("")
            }

            if let failure = message.failure {
                lines.append("> **Error:** \(failure.message)")
                if let next = failure.nextStep { lines.append("> \(next)") }
            } else if !message.text.isEmpty {
                lines.append(message.text)
            }
            lines.append("")

            for invocation in message.toolInvocations {
                lines.append("- Action `\(invocation.toolName)`: \(invocation.summary) (\(invocation.outcome.rawValue))")
            }
            if !message.toolInvocations.isEmpty { lines.append("") }

            if !message.citations.isEmpty {
                lines.append("Sources:")
                for (index, citation) in message.citations.enumerated() {
                    lines.append("\(index + 1). [\(citation.title)](\(citation.url.absoluteString))")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    func plainText(_ conversation: Conversation) -> String {
        let stamp = DateFormatter()
        stamp.dateStyle = .short
        stamp.timeStyle = .short
        var lines = [conversation.title, ""]
        for message in conversation.messages {
            let speaker = message.role == .user ? "You" : (message.role == .assistant ? "ScreenMate" : "System")
            lines.append("[\(stamp.string(from: message.createdAt))] \(speaker):")
            lines.append(message.failure?.message ?? message.text)
            for citation in message.citations {
                lines.append("    source: \(citation.url.absoluteString)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
