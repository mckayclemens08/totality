import Foundation

/// Moves an install from before content was kept per account into the owner's own space: the sealed
/// folders into `Accounts/<owner>/`, and the secrets into the owner's prefixed names. Nothing is deleted
/// until its copy is proven, and every step can be repeated, so a crash anywhere just resumes on the next
/// launch. Keys are only ever moved, never made or derived here.
public struct AccountDataMigration: Sendable {
    /// The folder accounts' own folders sit in, inside each base folder.
    public static let accountsFolder = "Accounts"
    /// Where the content key ring kept the owner, before content was per account.
    static let ownerSlot = "content-key-owner"

    /// The content key's store, which names the owner.
    let contentKeys: any ListableKeyStore
    /// Other stores whose items belong to the owner too, such as Google sign-ins and outside mail passwords.
    let otherKeys: [any ListableKeyStore]
    /// Base folders whose children, other than `Accounts`, are the owner's.
    let folders: [URL]

    public init(contentKeys: any ListableKeyStore, otherKeys: [any ListableKeyStore], folders: [URL]) {
        self.contentKeys = contentKeys
        self.otherKeys = otherKeys
        self.folders = folders
    }

    public static func folder(for account: String, in base: URL) -> URL {
        base.appendingPathComponent(accountsFolder, isDirectory: true).appendingPathComponent(account, isDirectory: true)
    }

    /// True while anything from before is left to move.
    public func isNeeded() throws -> Bool {
        if try !legacyNames(contentKeys).isEmpty { return true }
        for store in otherKeys where try !legacyNames(store).isEmpty { return true }
        return try folders.contains { try !legacyChildren(of: $0).isEmpty }
    }

    /// The owner is whoever the device's key was claimed for. An install that never claimed it goes to
    /// the account signed in now, as claiming it would have. With neither, it waits.
    public func owner(signedInAccount: String?) throws -> String? {
        if let stored = try contentKeys.load(Self.ownerSlot) { return String(decoding: stored, as: UTF8.self) }
        return signedInAccount
    }

    /// Moves everything to the owner, and returns who that was. Nil when there was nothing to move, or
    /// no one to move it to yet.
    @discardableResult
    public func run(signedInAccount: String?) throws -> String? {
        guard try isNeeded(), let owner = try owner(signedInAccount: signedInAccount) else { return nil }
        // Folders first: the owner slot moves last, so a crash before then still knows whose this is.
        for base in folders { try moveFolders(in: base, to: owner) }
        for store in otherKeys { try moveKeys(in: store, to: owner, last: nil) }
        try moveKeys(in: contentKeys, to: owner, last: Self.ownerSlot)
        return owner
    }

    // MARK: Folders

    private func legacyChildren(of base: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != Self.accountsFolder }
    }

    private func moveFolders(in base: URL, to owner: String) throws {
        let target = Self.folder(for: owner, in: base)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for child in try legacyChildren(of: base) {
            try move(child, into: target.appendingPathComponent(child.lastPathComponent))
        }
    }

    /// A rename where nothing is in the way. Where an earlier run already put part of a folder, the rest
    /// joins it file by file, and a file already there is kept rather than overwritten.
    private func move(_ source: URL, into destination: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: destination.path) else {
            try files.moveItem(at: source, to: destination)
            return
        }
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: source.path, isDirectory: &isFolder), isFolder.boolValue else {
            // A file already moved by an earlier run. The copy there is the one in use from now on, so the
            // old one is set aside under the owner instead of being lost or overwriting it.
            let aside = destination.deletingLastPathComponent()
                .appendingPathComponent(destination.lastPathComponent + ".before-accounts")
            if !files.fileExists(atPath: aside.path) { try files.moveItem(at: source, to: aside) }
            return
        }
        for child in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try move(child, into: destination.appendingPathComponent(child.lastPathComponent))
        }
        if try files.contentsOfDirectory(atPath: source.path).isEmpty { try files.removeItem(at: source) }
    }

    // MARK: Keys

    private func legacyNames(_ store: any ListableKeyStore) throws -> [String] {
        try store.names().filter { !$0.hasPrefix("account.") }
    }

    /// Copies each item to the owner's name, reads it back, and only then deletes the old one. An item
    /// the owner already holds with different contents is never overwritten: both stay, and the move stops.
    private func moveKeys(in store: any ListableKeyStore, to owner: String, last: String?) throws {
        let prefix = AccountKeyStore.prefix(for: owner)
        let legacy = try legacyNames(store)
        let names = legacy.filter { $0 != last } + legacy.filter { $0 == last }
        for name in names {
            guard let data = try store.load(name) else { continue }
            if let existing = try store.load(prefix + name) {
                guard existing == data else { throw AccountDataMigrationError.conflict(name) }
            } else {
                try store.save(data, as: prefix + name)
                guard try store.load(prefix + name) == data else { throw AccountDataMigrationError.notSaved(name) }
            }
            try store.delete(name)
        }
    }
}

public enum AccountDataMigrationError: Error, Equatable {
    /// The owner already has a different item by this name. Neither is touched.
    case conflict(String)
    /// The copy didn't read back the same, so the original stays.
    case notSaved(String)
}
