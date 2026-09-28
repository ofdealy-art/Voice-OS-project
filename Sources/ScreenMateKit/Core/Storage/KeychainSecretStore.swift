import Foundation
import Security
import ScreenMateCore

/// Stores API keys as generic password items in the user's login Keychain.
///
/// Keys are never written to `UserDefaults`, a plist, a log line, or the
/// conversation store. `kSecAttrAccessibleWhenUnlocked` means they are readable
/// only while the Mac is unlocked.
public struct KeychainSecretStore: SecretStoring {
    /// One service name for all of ScreenMate's items, so `removeAllSecrets`
    /// can clear them in a single call.
    public let service: String

    public init(service: String = "com.screenmate.ScreenMate") {
        self.service = service
    }

    public func secret(forKey key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.keychainFailure(status: status)
        }
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        guard !value.isEmpty else {
            try removeSecret(forKey: key)
            return
        }
        let data = Data(value.utf8)

        // Try to update an existing item first; add it only if none exists. The
        // other order leaves duplicates behind.
        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AppError.keychainFailure(status: updateStatus)
        }

        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AppError.keychainFailure(status: addStatus)
        }
    }

    public func removeSecret(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychainFailure(status: status)
        }
    }

    public func removeAllSecrets() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychainFailure(status: status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
