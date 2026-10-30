import Foundation
import Security

public enum KeyStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Where a device keeps secrets. Key backup over Matrix SSSS will sit behind this same protocol.
public protocol KeyStore: Sendable {
    func load(_ name: String) throws -> Data?
    func save(_ data: Data, as name: String) throws
    func delete(_ name: String) throws
}

/// Secrets stay on this device: they are excluded from iCloud Keychain and device backups, and
/// need the device to be unlocked.
public struct KeychainKeyStore: KeyStore {
    private let service: String

    public init(service: String = "app.totality.keys") {
        self.service = service
    }

    private func query(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load(_ name: String) throws -> Data? {
        var request = query(name)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError.unexpectedStatus(status) }
        return item as? Data
    }

    public func save(_ data: Data, as name: String) throws {
        try delete(name)
        var request = query(name)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.unexpectedStatus(status) }
    }

    public func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }
}
