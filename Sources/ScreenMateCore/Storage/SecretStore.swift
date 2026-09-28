import Foundation

/// Where API keys live. The only implementation that ships is Keychain-backed
/// (in `ScreenMateKit`); nothing in ScreenMate writes a key to `UserDefaults`,
/// to a plist, or to a log.
public protocol SecretStoring: Sendable {
    func secret(forKey key: String) throws -> String?
    func setSecret(_ value: String, forKey key: String) throws
    func removeSecret(forKey key: String) throws
    /// Used by "delete all my data".
    func removeAllSecrets() throws
}

public extension SecretStoring {
    func hasSecret(forKey key: String) -> Bool {
        (try? secret(forKey: key))?.isEmpty == false
    }
}

/// The account names ScreenMate uses inside its Keychain item. Centralised so a
/// rename cannot orphan a user's stored key.
public enum SecretKey {
    public static func chatProvider(_ providerID: String) -> String { "provider.\(providerID).apiKey" }
    public static func searchProvider(_ providerID: String) -> String { "search.\(providerID).apiKey" }
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    public init(_ storage: [String: String] = [:]) {
        self.storage = storage
    }

    public func secret(forKey key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func removeSecret(forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func removeAllSecrets() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
