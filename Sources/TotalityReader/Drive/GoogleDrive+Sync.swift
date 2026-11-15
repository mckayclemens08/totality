import Foundation
import TotalityCore

/// What every device of one person shares about Google Drive: the linked folders and the files opened
/// from them. It's one record per person, sealed with the content key and synced like the Reader's own
/// items. Folder names, file titles and Google addresses stay inside the seal. Listings, downloaded
/// files, Drive's change tokens and the Google sign-in never leave the device.
struct DriveShared: MergedRecord {
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

    /// Where the shared record lives. The label gives its ID with the key, and must never change.
    var shared: SealedRecordStore<DriveShared> {
        SealedRecordStore(store: store, rootKey: rootKey, kind: .readerDrive, label: "reader-drive-shared", suffix: Self.sharedSuffix, purpose: .googleDrive)
    }

    /// Nil when there's none yet.
    func loadShared() throws -> DriveShared? {
        try shared.load()?.normalized()
    }

    func writeShared(_ value: DriveShared) throws {
        guard !isClosed else { throw ReaderError.closed }
        try shared.write(value)
    }
}

/// The shared record, as sync reaches it. Everything goes through `SealedRecordStore`.
extension GoogleDrive: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.readerDrive] }

    public func sealedObjectIDs() throws -> [UUID] {
        try shared.ids()
    }

    public func sealedHash(of id: UUID) throws -> String? {
        try shared.object(id)?.hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        try shared.object(id)
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        try shared.verified(id)
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw ReaderError.closed }
        try shared.take(object, ifLocalHash: expected, pending: &pendingMerge)
        try prune()
    }

    /// A server's word that the record was deleted can't be proved, and nothing here ever deletes it, so
    /// it stays. The next sync sends it back.
    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {}

    public func deletedObjectIDs() throws -> Set<UUID> { [] }

    public func clearDeletion(_ id: UUID) throws {}

    /// Links and opened files from either side, minus what either removed.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        pendingMerge = try shared.conflict(local: local, remote: remote)
        return .keepRemote
    }

    public func emptyOldTrash() throws {}
}
