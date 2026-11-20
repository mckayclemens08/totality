import Foundation
import Security

public enum KeyStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case keyMissing
}

/// Where a device keeps secrets. Key backup over Matrix SSSS will sit behind this same protocol.
public protocol KeyStore: Sendable {
    func load(_ name: String) throws -> Data?
    func save(_ data: Data, as name: String) throws
    func delete(_ name: String) throws
}

/// A store that can say what it holds, by name only, so its items can be moved to an account.
public protocol ListableKeyStore: KeyStore {
    func names() throws -> [String]
}

/// One account's corner of a shared store: every name is prefixed with the account, so two accounts on
/// one device never read, overwrite or delete each other's secrets.
public struct AccountKeyStore: KeyStore {
    public static func prefix(for account: String) -> String { "account.\(account)." }

    private let base: any KeyStore
    private let prefix: String

    public init(_ base: any KeyStore, account: String) {
        self.base = base
        prefix = Self.prefix(for: account)
    }

    public func load(_ name: String) throws -> Data? { try base.load(prefix + name) }
    public func save(_ data: Data, as name: String) throws { try base.save(data, as: prefix + name) }
    public func delete(_ name: String) throws { try base.delete(prefix + name) }
}

extension ContentRootKey {
    static let keyStoreName = "content-root-key"

    /// Only creates a key on a true first run. A read error, or sealed data with no key to open it,
    /// stops here: a new root would sit beside the old data and split the person's content in two.
    /// Every module's storage has to be counted. A key is only safe to create when nothing anywhere
    /// is sealed under the one that's missing.
    public static func loadOrCreate(in store: any KeyStore, sealedIn stores: [any BlobStore]) throws -> ContentRootKey {
        try loadOrCreate(in: store, hasSealedData: stores.contains { try !$0.names().isEmpty })
    }

    static func loadOrCreate(in store: any KeyStore, hasSealedData: Bool) throws -> ContentRootKey {
        if let stored = try store.load(keyStoreName) {
            return try ContentRootKey(bytes: stored)
        }
        guard !hasSealedData else { throw KeyStoreError.keyMissing }
        let key = try generate()
        try store.save(key.bytes, as: keyStoreName)
        return key
    }
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

extension KeychainKeyStore: ListableKeyStore {
    /// The names of this service's items. Never their contents.
    public func names() throws -> [String] {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeyStoreError.unexpectedStatus(status) }
        return (items as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
