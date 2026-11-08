import Foundation
import TotalityCore

/// Where the Matrix SDK keeps an account's session and crypto stores, inside the app's own container.
/// Each Totality account gets its own folder, so a second account on the device starts from nothing.
public struct MessagesStorePaths: Sendable {
    public let data: URL
    public let cache: URL

    public init(account: String, fileManager: FileManager = .default) throws {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try self.init(account: account, support: support, caches: caches, fileManager: fileManager)
    }

    init(account: String, support: URL, caches: URL, fileManager: FileManager = .default) throws {
        // The account ID goes into a path, so only the shape Supabase gives it is allowed.
        guard account.wholeMatch(of: /[0-9a-f-]{36}/) != nil else { throw MessagesError.notSignedIn }
        data = support.appendingPathComponent("Messages/\(account)", isDirectory: true)
        cache = caches.appendingPathComponent("Messages/\(account)", isDirectory: true)
        for folder in [data, cache] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The stores are encrypted with a key that stays in this device's Keychain, so a backup of
        // the folder alone is useless. It's left out of backups anyway.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = data
        try? marked.setResourceValues(values)
    }

    public var isEmpty: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: data.path).isEmpty) ?? true
    }
}

/// The Keychain names for an account's store key and Matrix session.
public struct MessagesSecrets: Sendable {
    let keys: any KeyStore
    let account: String

    public init(keys: any KeyStore, account: String) {
        self.keys = keys
        self.account = account
    }

    public var sessionName: String { "\(account).session" }
    public var storeKeyName: String { "\(account).store-key" }

    /// A reinstall empties the container but keeps the Keychain, and a restored backup can bring a
    /// store back without its key. Either way the store and session can't be used together, so both
    /// start again and this device signs in as a new Matrix device.
    public func storeKey(for paths: MessagesStorePaths, fileManager: FileManager = .default) throws -> Data {
        if let saved = try keys.load(storeKeyName), !paths.isEmpty { return saved }
        try keys.delete(sessionName)
        for folder in [paths.data, paths.cache] {
            for item in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try fileManager.removeItem(at: item)
            }
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw MessagesError.failed("This device couldn't make a key for Messages.") }
        try keys.save(bytes, as: storeKeyName)
        return bytes
    }
}
