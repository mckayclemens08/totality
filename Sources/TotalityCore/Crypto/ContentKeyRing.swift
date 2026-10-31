import Foundation

public enum ContentKeyError: Error, Equatable {
    /// This device's content belongs to a different account.
    case otherAccount
}

/// One module's sealed storage, and which key purpose each kind of blob uses.
public struct SealedArea: Sendable {
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
        return try ContentRootKey.loadOrCreate(in: keys, sealedIn: areas.map(\.store))
    }

    /// Makes `new` this device's key. With no key here at all, this is a recovery: whatever is on the
    /// device was sealed by the key being restored, so nothing needs moving.
    public func adopt(_ new: ContentRootKey) throws -> KeyMoveReport {
        if try keys.load(Slot.incoming) != nil { _ = try finishMove() }
        guard let stored = try keys.load(Slot.current) else {
            try keys.save(new.bytes, as: Slot.current)
            return KeyMoveReport(moved: 0, unreadable: try countUnreadable(with: new))
        }
        let old = try ContentRootKey(bytes: stored)
        guard old != new else { return KeyMoveReport(moved: 0, unreadable: 0) }
        try keys.save(old.bytes, as: Slot.previous)
        try keys.save(new.bytes, as: Slot.incoming)
        return try finishMove()
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
