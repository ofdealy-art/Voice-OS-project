import Foundation

public protocol ConversationStoring: Sendable {
    func summaries() throws -> [ConversationSummary]
    func load(id: UUID) throws -> Conversation?
    func save(_ conversation: Conversation) throws
    func delete(id: UUID) throws
    func deleteAll() throws
    /// Removes conversations older than `maxAge`. Returns how many went.
    func pruneOlderThan(_ maxAge: TimeInterval, now: Date) throws -> Int
}

/// One JSON file per conversation under Application Support.
///
/// Files are written with owner-only permissions and replaced atomically, and
/// `deleteAll` removes the directory outright so "delete my data" leaves nothing
/// behind.
public final class FileConversationStore: ConversationStoring, @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        try createDirectoryIfNeeded()
    }

    /// `~/Library/Application Support/ScreenMate/Conversations`
    public static func defaultDirectory(
        fileManager: FileManager = .default,
        bundleFolderName: String = "ScreenMate"
    ) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppError.storageFailure(detail: "Application Support is not reachable")
        }
        return support
            .appendingPathComponent(bundleFolderName, isDirectory: true)
            .appendingPathComponent("Conversations", isDirectory: true)
    }

    private func createDirectoryIfNeeded() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AppError.storageFailure(detail: error.localizedDescription)
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    public func summaries() throws -> [ConversationSummary] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [ConversationSummary] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conversation = try? decoder.decode(Conversation.self, from: data) else {
                continue // A single unreadable file must not hide the rest.
            }
            result.append(ConversationSummary(conversation))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: UUID) throws -> Conversation? {
        lock.lock(); defer { lock.unlock() }
        let file = url(for: id)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            return try decoder.decode(Conversation.self, from: data)
        } catch {
            throw AppError.storageFailure(detail: "conversation \(id.uuidString) could not be read")
        }
    }

    public func save(_ conversation: Conversation) throws {
        lock.lock(); defer { lock.unlock() }
        try createDirectoryIfNeeded()
        let file = url(for: conversation.id)
        do {
            let data = try encoder.encode(conversation)
            // `.atomic` writes to a temp file and renames, so a crash mid-write
            // cannot leave a half-written transcript behind.
            try data.write(to: file, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.storageFailure(detail: error.localizedDescription)
        }
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let file = url(for: id)
        guard fileManager.fileExists(atPath: file.path) else { return }
        do {
            try fileManager.removeItem(at: file)
        } catch {
            throw AppError.storageFailure(detail: error.localizedDescription)
        }
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            throw AppError.storageFailure(detail: error.localizedDescription)
        }
        try createDirectoryIfNeeded()
    }

    public func pruneOlderThan(_ maxAge: TimeInterval, now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-maxAge)
        let expired = try summaries().filter { $0.updatedAt < cutoff }
        for summary in expired {
            try delete(id: summary.id)
        }
        return expired.count
    }
}

public final class InMemoryConversationStore: ConversationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: Conversation] = [:]

    public init(_ conversations: [Conversation] = []) {
        for conversation in conversations {
            storage[conversation.id] = conversation
        }
    }

    public func summaries() throws -> [ConversationSummary] {
        lock.lock(); defer { lock.unlock() }
        return storage.values
            .map(ConversationSummary.init)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: UUID) throws -> Conversation? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    public func save(_ conversation: Conversation) throws {
        lock.lock(); defer { lock.unlock() }
        storage[conversation.id] = conversation
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: id)
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }

    public func pruneOlderThan(_ maxAge: TimeInterval, now: Date) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-maxAge)
        let expired = storage.filter { $0.value.updatedAt < cutoff }.map(\.key)
        for id in expired { storage.removeValue(forKey: id) }
        return expired.count
    }
}

/// Used when "Save conversations" is off: everything is dropped on the floor, so
/// nothing reaches disk even transiently.
public struct NullConversationStore: ConversationStoring {
    public init() {}
    public func summaries() throws -> [ConversationSummary] { [] }
    public func load(id: UUID) throws -> Conversation? { nil }
    public func save(_ conversation: Conversation) throws {}
    public func delete(id: UUID) throws {}
    public func deleteAll() throws {}
    public func pruneOlderThan(_ maxAge: TimeInterval, now: Date) throws -> Int { 0 }
}
