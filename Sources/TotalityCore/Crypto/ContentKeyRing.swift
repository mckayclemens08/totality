import Foundation

public enum ContentKeyError: Error, Equatable {
    /// This device's content belongs to a different account.
    case otherAccount
    /// The key opens nothing on this device, so it can't be the right one.
    case keyDoesNotOpenContent
    /// This can't be done while there's content here, or after joining a backup.
    case notAllowedNow
}

/// One module's sealed storage, and which key purpose each kind of blob uses.
public struct SealedArea: Sendable {
    /// A vault's record that something was deleted. It holds no content, so it doesn't count as any.
    public static let deletionSuffix = ".deleted"

    public let store: any BlobStore
    /// File suffix to purpose, like ".event" to `.event`.
    public let purposes: [String: KeyPurpose]

    public init(store: any BlobStore, purposes: [String: KeyPurpose]) {
        self.store = store
        self.purposes = purposes
    }
}

public struct KeyMoveReport: Sendable, Equatable {
    public let moved: Int
    /// Blobs neither key opens. They're left untouched.
    public let unreadable: Int

    public init(moved: Int, unreadable: Int) {
        self.moved = moved
        self.unreadable = unreadable
    }
}

/// This device's content key, and the one dangerous thing that ever happens to it: moving every sealed
/// blob to a different key. Each step is recorded before the next begins, so a crash at any point
/// resumes on the next launch, and both keys survive until the work is proven.
public struct ContentKeyRing: Sendable {
    private enum Slot {
        static let current = ContentRootKey.keyStoreName
        static let incoming = "content-root-key.incoming"
        static let previous = "content-root-key.previous"
        static let backupFingerprint = "content-key-backup-fingerprint"
        static let owner = "content-key-owner"
        static let ownerSettled = "content-key-owner-settled"
    }

    private let keys: any KeyStore
    private let areas: [SealedArea]

    public init(keys: any KeyStore, areas: [SealedArea]) {
        self.keys = keys
        self.areas = areas
    }

    /// The key to open content with. A move that was interrupted finishes first, because until it
    /// does, some blobs are under each key.
    public func current() throws -> ContentRootKey {
        if try keys.load(Slot.incoming) != nil { _ = try finishMove() }
        return try ContentRootKey.loadOrCreate(in: keys, hasSealedData: hasSealedContent())
    }

    /// Makes `new` this device's key. With no key here at all, this is a recovery: whatever is on the
    /// device was sealed by the key being restored, so nothing needs moving. If it opens none of it,
    /// it's the wrong key, and it's refused rather than left in place over content it can't read.
    public func adopt(_ new: ContentRootKey) throws -> KeyMoveReport {
        if try keys.load(Slot.incoming) != nil { _ = try finishMove() }
        guard let stored = try keys.load(Slot.current) else {
            guard try !hasSealedContent() || opensSomething(new) else { throw ContentKeyError.keyDoesNotOpenContent }
            try keys.save(new.bytes, as: Slot.current)
            return KeyMoveReport(moved: 0, unreadable: try countUnreadable(with: new))
        }
        let old = try ContentRootKey(bytes: stored)
        guard old != new else { return KeyMoveReport(moved: 0, unreadable: 0) }
        try keys.save(old.bytes, as: Slot.previous)
        try keys.save(new.bytes, as: Slot.incoming)
        return try finishMove()
    }

    private func opensSomething(_ key: ContentRootKey) throws -> Bool {
        for area in areas {
            for name in try area.store.names() {
                guard let (id, purpose) = area.identify(name), let sealed = try area.store.read(name) else { continue }
                if (try? ContentCipher.open(sealed, key: key.objectKey(for: id, purpose: purpose), objectID: id)) != nil {
                    return true
                }
            }
        }
        return false
    }

    private func countUnreadable(with key: ContentRootKey) throws -> Int {
        var unreadable = 0
        for area in areas {
            for name in try area.store.names() {
                guard let (id, purpose) = area.identify(name), let sealed = try area.store.read(name) else { continue }
                if (try? ContentCipher.open(sealed, key: key.objectKey(for: id, purpose: purpose), objectID: id)) == nil {
                    unreadable += 1
                }
            }
        }
        return unreadable
    }

    /// Safe to repeat: a blob already under the new key is skipped.
    private func finishMove() throws -> KeyMoveReport {
        guard let incoming = try keys.load(Slot.incoming), let previous = try keys.load(Slot.previous) else {
            throw KeyStoreError.keyMissing
        }
        let new = try ContentRootKey(bytes: incoming)
        let old = try ContentRootKey(bytes: previous)
        var report = (moved: 0, unreadable: 0)
        for area in areas {
            for name in try area.store.names() {
                guard let (id, purpose) = area.identify(name), let sealed = try area.store.read(name) else { continue }
                let newKey = new.objectKey(for: id, purpose: purpose)
                if (try? ContentCipher.open(sealed, key: newKey, objectID: id)) != nil { continue }
                guard let plain = try? ContentCipher.open(sealed, key: old.objectKey(for: id, purpose: purpose), objectID: id) else {
                    report.unreadable += 1
                    continue
                }
                try area.store.write(try ContentCipher.seal(plain, key: newKey, objectID: id), as: name)
                // Proven by reading back from storage, because the old copy is gone once this returns.
                guard let written = try area.store.read(name),
                      try ContentCipher.open(written, key: newKey, objectID: id) == plain
                else { throw CryptoError.authenticationFailed }
                report.moved += 1
            }
        }
        try keys.save(new.bytes, as: Slot.current)
        try keys.delete(Slot.incoming)
        if report.unreadable == 0 { try keys.delete(Slot.previous) }
        return KeyMoveReport(moved: report.moved, unreadable: report.unreadable)
    }

    /// The account whose key this is, once one has claimed it.
    public func owner() throws -> String? {
        try keys.load(Slot.owner).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Ties this device's key to one account for good. Content isn't kept per account yet, so without
    /// this a second person signing in here could lock the first person's key into their own backup.
    public func claim(for account: String) throws {
        if let owner = try owner() {
            guard owner == account else { throw ContentKeyError.otherAccount }
            return
        }
        try keys.save(Data(account.utf8), as: Slot.owner)
    }

    /// Hands the device to `account`, which has proved the content is theirs. The proof is holding this
    /// device's own key. Opening a blob is only enough when no key is left to compare with, because one
    /// planted blob would otherwise let someone take over everything else here.
    public func reassign(to account: String, provenBy key: ContentRootKey) throws {
        if try keys.load(Slot.incoming) != nil { _ = try finishMove() }
        if let stored = try keys.load(Slot.current) {
            guard stored == key.bytes else { throw ContentKeyError.keyDoesNotOpenContent }
        } else {
            guard try opensSomething(key) else { throw ContentKeyError.keyDoesNotOpenContent }
        }
        try keys.save(Data(account.utf8), as: Slot.owner)
    }

    /// The owner gives the device up, for a device claimed by the wrong account. Not after joining a
    /// backup, because the account's recovery key is then tied to this key.
    public func release(by account: String) throws {
        guard try owner() == account else { throw ContentKeyError.otherAccount }
        guard try joinedBackup() == nil else { throw ContentKeyError.notAllowedNow }
        try keys.delete(Slot.owner)
    }

    /// Clears a device with nothing on it, so a new account starts with a key of its own and the old
    /// one can't end up in the new account's backup. Refused if there's any content at all.
    public func resetEmptyDevice() throws {
        let isEmpty = try areas.allSatisfy { area in
            try area.store.names().allSatisfy { $0.hasSuffix(SealedArea.deletionSuffix) }
        }
        guard isEmpty, try keys.load(Slot.incoming) == nil else { throw ContentKeyError.notAllowedNow }
        for area in areas {
            for name in try area.store.names() { try area.store.delete(name) }
        }
        for slot in [Slot.current, Slot.previous, Slot.owner, Slot.backupFingerprint] {
            try keys.delete(slot)
        }
    }

    /// Runs once. An install from before accounts owned keys already has one person's content and
    /// session, so that account is the owner. Everyone after has to be asked or start empty, which is
    /// why this never runs again: a later session on this device could be anyone's.
    public func settleExistingInstall(signedInAccount: String?) throws {
        guard try keys.load(Slot.ownerSettled) == nil else { return }
        if let signedInAccount, try owner() == nil { try claim(for: signedInAccount) }
        try keys.save(Data([1]), as: Slot.ownerSettled)
    }

    public func hasSealedContent() throws -> Bool {
        try areas.contains { area in try area.store.names().contains { area.identify($0) != nil } }
    }

    /// The fingerprint of the backup this device joined, if any.
    public func joinedBackup() throws -> String? {
        try keys.load(Slot.backupFingerprint).map { String(decoding: $0, as: UTF8.self) }
    }

    public func markJoined(_ fingerprint: String) throws {
        try keys.save(Data(fingerprint.utf8), as: Slot.backupFingerprint)
    }
}

extension SealedArea {
    fileprivate func identify(_ name: String) -> (id: UUID, purpose: KeyPurpose)? {
        for (suffix, purpose) in purposes where name.hasSuffix(suffix) {
            if let id = UUID(uuidString: String(name.dropLast(suffix.count))) { return (id, purpose) }
        }
        return nil
    }
}
