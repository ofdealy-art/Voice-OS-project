import Foundation

public protocol SettingsStoring: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings) throws
    func reset() throws
}

/// Settings live in `UserDefaults` (they are preferences, not secrets), while
/// API keys live in the Keychain. Stored as one JSON blob so adding a preference
/// never needs a migration.
public struct UserDefaultsSettingsStore: SettingsStoring {
    public static let defaultKey = "com.screenmate.settings.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // A corrupt blob must not brick the app; fall back to defaults and
            // let the next save overwrite it.
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) throws {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: key)
        } catch {
            throw AppError.storageFailure(detail: "settings could not be encoded")
        }
    }

    public func reset() throws {
        defaults.removeObject(forKey: key)
    }
}

/// For tests and previews.
public final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings
    public private(set) var saveCount = 0

    public init(_ settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
        saveCount += 1
    }

    public func reset() throws {
        lock.lock(); defer { lock.unlock() }
        settings = AppSettings()
    }
}
