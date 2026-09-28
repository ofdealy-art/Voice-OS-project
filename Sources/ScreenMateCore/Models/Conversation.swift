import Foundation

public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    /// Which provider/model produced this transcript, for display and export.
    public var providerID: String?
    public var modelID: String?

    public init(
        id: UUID = UUID(),
        title: String = "New conversation",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        providerID: String? = nil,
        modelID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.providerID = providerID
        self.modelID = modelID
    }

    /// Derives a short title from the first user message, the way Messages and
    /// Mail do. Called after the first exchange completes.
    public mutating func refreshTitleFromContent(limit: Int = 48) {
        guard title == "New conversation" || title.isEmpty else { return }
        guard let first = messages.first(where: { $0.role == .user && !$0.text.isEmpty }) else { return }
        let collapsed = first.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return }
        if collapsed.count <= limit {
            title = collapsed
        } else {
            let cut = collapsed.prefix(limit)
            // Prefer a word boundary so titles do not end mid-word.
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
                title = String(cut[cut.startIndex..<space]) + "…"
            } else {
                title = String(cut) + "…"
            }
        }
    }
}

/// Lightweight row used by the conversation list without loading every message.
public struct ConversationSummary: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let messageCount: Int

    public init(id: UUID, title: String, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }

    public init(_ conversation: Conversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.updatedAt = conversation.updatedAt
        self.messageCount = conversation.messages.count
    }
}
