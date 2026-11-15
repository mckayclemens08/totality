import Foundation
import TotalityCore

/// What every device of one person shares about Google Drive: the linked folders and the files opened
/// from them. It's one record per person, sealed with the content key and synced like the Reader's own
/// items. Folder names, file titles and Google addresses stay inside the seal. Listings, downloaded
/// files, Drive's change tokens and the Google sign-in never leave the device.
struct DriveShared: Codable, Equatable, Sendable {
    var links: [DriveLink] = []
    var recent: [DriveRecent] = []
    /// When a link or an opened entry was removed, by `"account/id"`, so an older copy on another device
    /// can't bring it back. Linking or opening it again later counts, because that's newer.
    var removed: [String: Date] = [:]
    /// When each Google account was disconnected. Anything of it from before then goes everywhere.
    var forgotten: [String: Date] = [:]

    /// The most removals remembered. Older ones are long since everywhere.
    static let mostRemoved = 500

    init(links: [DriveLink] = [], recent: [DriveRecent] = [], removed: [String: Date] = [:], forgotten: [String: Date] = [:]) {
        self.links = links
        self.recent = recent
        self.removed = removed
        self.forgotten = forgotten
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        links = try values.decodeIfPresent([DriveLink].self, forKey: .links) ?? []
        recent = try values.decodeIfPresent([DriveRecent].self, forKey: .recent) ?? []
        removed = try values.decodeIfPresent([String: Date].self, forKey: .removed) ?? [:]
        forgotten = try values.decodeIfPresent([String: Date].self, forKey: .forgotten) ?? [:]
    }

    /// Two devices' copies as one: everything either has, the newest of each, minus what either removed.
    static func merged(_ one: DriveShared, _ other: DriveShared) -> DriveShared {
        DriveShared(
            links: one.links + other.links,
            recent: one.recent + other.recent,
            removed: one.removed.merging(other.removed, uniquingKeysWith: max),
            forgotten: one.forgotten.merging(other.forgotten, uniquingKeysWith: max)
        ).normalized()
    }

    /// One of each, newest first for what was opened and oldest first for links, with removals applied.
    func normalized() -> DriveShared {
        func gone(_ key: String, account: String, at date: Date) -> Bool {
            removed[key].map { $0 >= date } == true || forgotten[account].map { $0 >= date } == true
        }
        var linksByKey: [String: DriveLink] = [:]
        for link in links where !gone(link.id, account: link.account, at: link.linkedAt) {
            if let kept = linksByKey[link.id], kept.linkedAt >= link.linkedAt { continue }
            linksByKey[link.id] = link
        }
        var recentByKey: [String: DriveRecent] = [:]
        for entry in recent where !gone(entry.key, account: entry.account, at: entry.openedAt) {
            // A folder is only remembered while it's linked.
            if entry.isFolder, linksByKey[entry.key] == nil { continue }
            if let kept = recentByKey[entry.key], kept.openedAt >= entry.openedAt { continue }
            recentByKey[entry.key] = entry
        }
        var files = 0
        let recent = recentByKey.values.sorted { ($0.openedAt, $0.key) > ($1.openedAt, $1.key) }.filter { entry in
            guard !entry.isFolder else { return true }
            files += 1
            return files <= GoogleDrive.mostRecent
        }
        let latestRemoved = Dictionary(uniqueKeysWithValues: removed.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(Self.mostRemoved).map { ($0.key, $0.value) })
        return DriveShared(
            links: linksByKey.values.sorted { ($0.linkedAt, $0.id) < ($1.linkedAt, $1.id) },
            recent: recent, removed: latestRemoved, forgotten: forgotten
        )
    }

    /// This copy after `next` replaced it on this device: whatever went is remembered as removed.
    func changed(to next: DriveShared, at date: Date) -> DriveShared {
        var next = next
        let kept = Set(next.links.map(\.id)).union(next.recent.map(\.key))
        for key in Set(links.map(\.id)).union(recent.map(\.key)) where !kept.contains(key) {
            next.removed[key] = date
        }
        next.removed.merge(removed, uniquingKeysWith: max)
        next.forgotten.merge(forgotten, uniquingKeysWith: max)
        return next.normalized()
    }
}

extension GoogleDrive {
    static let sharedSuffix = ".gdsync"

    static func sharedName(_ id: UUID) -> String { id.uuidString.lowercased() + sharedSuffix }

    /// Every copy of the shared record here. There's one, except briefly after a key move, when a
    /// device that hasn't synced yet starts its own; they're read together, so nothing is lost.
    func sharedIDs() throws -> [UUID] {
        try store.names().filter { $0.hasSuffix(Self.sharedSuffix) }.compactMap {
            UUID(uuidString: String($0.dropLast(Self.sharedSuffix.count)))
        }.sorted { $0.uuidString < $1.uuidString }
    }

    /// The ID it's written under. The same on every device with this key, and nobody else can work it out,
    /// so two people's records never meet on the server.
    func sharedID() throws -> UUID {
        try sharedIDs().first ?? rootKey.derivedID(from: "reader-drive-shared")
    }

    /// Nil when there's none yet. One this key can't open belongs to someone else, and is left out.
    func loadShared() throws -> DriveShared? {
        let copies = try sharedIDs().compactMap { id in try store.read(Self.sharedName(id)).flatMap { try? openShared($0, id: id) } }
        guard let first = copies.first else { return nil }
        return copies.dropFirst().reduce(first.normalized(), DriveShared.merged)
    }

    func writeShared(_ shared: DriveShared) throws {
        guard !isClosed else { throw ReaderError.closed }
        let id = try sharedID()
        try store.write(try sealShared(shared, id: id), as: Self.sharedName(id))
    }

    func sealShared(_ shared: DriveShared, id: UUID) throws -> Data {
        try ContentCipher.seal(JSONEncoder().encode(shared), key: rootKey.objectKey(for: id, purpose: .googleDrive), objectID: id)
    }

    func openShared(_ sealed: Data, id: UUID) throws -> DriveShared {
        try JSONDecoder().decode(DriveShared.self, from: ContentCipher.open(sealed, key: rootKey.objectKey(for: id, purpose: .googleDrive), objectID: id))
    }
}

/// The shared record, as sync reaches it. It travels as its own kind with everything in the sealed
/// details, so the server holds one opaque row per person.
extension GoogleDrive: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.readerDrive] }

    public func sealedObjectIDs() throws -> [UUID] {
        try sharedIDs()
    }

    public func sealedHash(of id: UUID) throws -> String? {
        try sealedObject(id)?.hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        try store.read(Self.sharedName(id)).map { SealedObject(id: id, kind: .readerDrive, meta: $0, body: nil) }
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        _ = try openShared(object.meta, id: id)
        return object
    }

    /// Only a record that opens under this key is taken, because a server can send anything. One that
    /// settled a conflict is written as the merge of both sides, which the next sync sends back up.
    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard object.kind == .readerDrive else { throw CryptoError.authenticationFailed }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        let incoming = try openShared(object.meta, id: object.id)
        if let pending = pendingMerge, pending.id == object.id, pending.remoteHash == object.hash {
            pendingMerge = nil
            try store.write(try sealShared(DriveShared.merged(pending.merged, incoming), id: object.id), as: Self.sharedName(object.id))
        } else {
            try store.write(object.meta, as: Self.sharedName(object.id))
        }
        try prune()
    }

    /// A server's word that the record was deleted can't be proved, and nothing here ever deletes it, so
    /// it stays. The next sync sends it back.
    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {}

    public func deletedObjectIDs() throws -> Set<UUID> { [] }

    public func clearDeletion(_ id: UUID) throws {}

    /// Both sides are kept: links and opened files from either, minus what either removed. Sync takes the
    /// other side's copy, and this device writes the merge in its place, which goes back up next time.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        let merged = DriveShared.merged(try openShared(local.meta, id: local.id), try openShared(remote.meta, id: remote.id))
        pendingMerge = PendingMerge(id: remote.id, remoteHash: remote.hash, merged: merged)
        return .keepRemote
    }

    public func emptyOldTrash() throws {}
}

struct PendingMerge: Sendable {
    let id: UUID
    let remoteHash: String
    let merged: DriveShared
}
