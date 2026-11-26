import Foundation
import TotalityCore

public struct ContactListing: Sendable, Equatable {
    /// Every card that opened, Recently Deleted included.
    public let cards: [ContactCard]
    /// Cards that would not open. The screen says so instead of hiding them, and they're kept.
    public let unreadable: Int
}

public enum ContactVaultError: Error, Equatable {
    case notFound, mismatched, closed
}

/// The person's own cards. Each is one sealed blob (kind `contact`, purpose `contact`) whose name holds
/// only its random ID, so the device's storage says no more than the server does: how many cards, their
/// sizes and when they change (issue 205, section 3).
public actor ContactVault {
    public static let sealedPurposes: [String: KeyPurpose] = [".contact": .contact, ".contact.trash": .contact]
    /// How long a card removed by another device stays recoverable here, and how long Recently Deleted keeps one.
    public static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var isClosed = false
    private var hashes: [UUID: String] = [:]
    private static let suffix = ".contact"

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    private func name(_ id: UUID) -> String { id.uuidString.lowercased() + Self.suffix }
    private func deletionName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).deleted" }
    private func trashStampName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).trashed" }

    /// Refuses all further writes, so nothing lands under the old key during a key move.
    public func close() {
        isClosed = true
    }

    private func seal(_ card: ContactCard) throws -> Data {
        let key = rootKey.objectKey(for: card.id, purpose: .contact)
        return try ContentCipher.seal(JSONEncoder().encode(card), key: key, objectID: card.id)
    }

    private func open(_ sealed: Data, id: UUID) throws -> ContactCard {
        let key = rootKey.objectKey(for: id, purpose: .contact)
        let card = try JSONDecoder().decode(ContactCard.self, from: ContentCipher.open(sealed, key: key, objectID: id))
        guard card.id == id else { throw ContactVaultError.mismatched }
        return card
    }

    public func save(_ card: ContactCard) throws {
        guard !isClosed else { throw ContactVaultError.closed }
        hashes[card.id] = nil
        try store.write(try seal(card), as: name(card.id))
    }

    /// Saves `card` over `original` only if nothing else changed it meanwhile. If a sync landed meanwhile,
    /// the newer of the two wins, so a change from another device is never silently undone by an older one.
    @discardableResult
    public func save(_ card: ContactCard, over original: ContactCard?) throws -> ContactCard {
        guard let original, let current = try? self.card(card.id), current != original else {
            try save(card)
            return card
        }
        let kept = current.updatedAt > card.updatedAt ? current : card
        try save(kept)
        return kept
    }

    public func card(_ id: UUID) throws -> ContactCard {
        guard let sealed = try store.read(name(id)) else { throw ContactVaultError.notFound }
        return try open(sealed, id: id)
    }

    public func everything() throws -> ContactListing {
        var cards: [ContactCard] = []
        var unreadable = 0
        for file in try store.names() where file.hasSuffix(Self.suffix) {
            guard let id = UUID(uuidString: String(file.dropLast(Self.suffix.count))) else { continue }
            do { cards.append(try card(id)) } catch is CryptoError, is DecodingError, is ContactVaultError { unreadable += 1 }
        }
        return ContactListing(cards: cards, unreadable: unreadable)
    }

    /// Deletes for good, here and, at the next sync, everywhere. Recently Deleted is a mark on the card
    /// (`deletedAt`); this is what emptying it does.
    public func delete(_ id: UUID) throws {
        guard !isClosed else { throw ContactVaultError.closed }
        // The record goes first, so a crash can't lose the fact that this was deleted on purpose.
        try store.write(Data(), as: deletionName(id))
        try store.delete(name(id))
        hashes[id] = nil
    }
}

extension ContactVault: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.contact] }

    public func sealedObjectIDs() throws -> [UUID] {
        // A crash can stop a delete halfway. The record says what was meant, so finish it.
        if !isClosed {
            for id in try deletedObjectIDs() where try store.exists(name(id)) {
                try store.delete(name(id))
                hashes[id] = nil
            }
        }
        return try store.names().compactMap { file in
            file.hasSuffix(Self.suffix) ? UUID(uuidString: String(file.dropLast(Self.suffix.count))) : nil
        }
    }

    public func sealedHash(of id: UUID) throws -> String? {
        if let known = hashes[id] { return known }
        let hash = try sealedObject(id)?.hash
        hashes[id] = hash
        return hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        guard let sealed = try store.read(name(id)) else { return nil }
        return SealedObject(id: id, kind: .contact, meta: sealed, body: nil)
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        try check(object)
        return object
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw ContactVaultError.closed }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        if expected == nil, try store.read(deletionName(object.id)) != nil { throw SyncError.changedLocally }
        try check(object)
        try store.write(object.meta, as: name(object.id))
        hashes[object.id] = nil
    }

    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {
        guard !isClosed else { throw ContactVaultError.closed }
        guard try sealedHash(of: id) == expected else { throw SyncError.changedLocally }
        guard let sealed = try store.read(name(id)) else { return }
        // The stamp goes first, so a crash can't leave trash that's never cleaned up.
        try store.write(Data(ISO8601DateFormatter().string(from: Date()).utf8), as: trashStampName(id))
        try store.write(sealed, as: name(id) + ".trash")
        try store.delete(name(id))
        hashes[id] = nil
    }

    public func emptyOldTrash() throws {
        guard !isClosed else { return }
        let formatter = ISO8601DateFormatter()
        for file in try store.names() where file.hasSuffix(".trashed") {
            guard let id = UUID(uuidString: String(file.dropLast(".trashed".count))),
                  let stamp = try store.read(file), let date = formatter.date(from: String(decoding: stamp, as: UTF8.self)),
                  Date().timeIntervalSince(date) > Self.trashLifetime
            else { continue }
            try store.delete(name(id) + ".trash")
            try store.delete(file)
        }
    }

    public func deletedObjectIDs() throws -> Set<UUID> {
        Set(try store.names().compactMap { file in
            file.hasSuffix(".deleted") ? UUID(uuidString: String(file.dropLast(".deleted".count))) : nil
        })
    }

    public func clearDeletion(_ id: UUID) throws {
        try store.delete(deletionName(id))
    }

    /// The newer card wins, whole. A tie keeps this device's.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        let mine = try check(local), theirs = try check(remote)
        return mine.updatedAt >= theirs.updatedAt ? .keepLocal : .keepRemote
    }

    /// Proves the object opens under this device's key as a card with its own ID.
    @discardableResult
    private func check(_ object: SealedObject) throws -> ContactCard {
        guard object.kind == .contact else { throw CryptoError.authenticationFailed }
        do {
            return try open(object.meta, id: object.id)
        } catch ContactVaultError.mismatched {
            throw CryptoError.authenticationFailed
        }
    }
}
