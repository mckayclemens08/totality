import CryptoKit
import Foundation

/// One item as it travels: sealed metadata, and a sealed body if it has one. The server sees these
/// bytes and nothing inside them.
public struct SealedObject: Sendable, Equatable {
    public let id: UUID
    public let kind: ContentKind
    public let meta: Data
    public let body: Data?

    public init(id: UUID, kind: ContentKind, meta: Data, body: Data?) {
        self.id = id
        self.kind = kind
        self.meta = meta
        self.body = body
    }

    /// Identifies these exact bytes. Sealing is randomized, so any change gives a new hash.
    public var hash: String {
        var hasher = SHA256()
        hasher.update(data: Data(SHA256.hash(data: meta)))
        hasher.update(data: Data(SHA256.hash(data: body ?? Data())))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Identifies just the body, so a change to the details alone doesn't move the whole file again.
    public var bodyHash: String? {
        body.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}

extension UUID {
    /// The same input always gives the same ID, so retrying can't make a second copy of something.
    public init(derivedFrom text: String) {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self = bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
}

public enum ConflictResolution: Sendable, Equatable {
    case keepLocal
    case keepRemote
}

/// A module's sealed storage, as sync reaches it. Everything crosses as ciphertext, so sync never
/// needs a key. Only the module opens anything: to check what arrives, to check what leaves, and to
/// settle a conflict.
public protocol SyncArea: Sendable {
    var kinds: Set<ContentKind> { get }
    func sealedObjectIDs() async throws -> [UUID]
    /// Nil when the item is gone, or is missing a part it needs, so sync treats it as missing here.
    func sealedHash(of id: UUID) async throws -> String?
    func sealedObject(_ id: UUID) async throws -> SealedObject?
    /// The item, after proving every part opens. Throws `CryptoError` if it's damaged, so a damaged
    /// file can never replace the good copy on the server.
    func verifiedObject(_ id: UUID) async throws -> SealedObject?
    /// Must refuse anything that doesn't open under this device's key, because a server can send
    /// anything. Must also throw `changedLocally` unless the item is still at `ifLocalHash`, so a
    /// save that lands during a sync is never overwritten.
    func store(_ object: SealedObject, ifLocalHash: String?) async throws
    /// Moves the item to a local trash, because a server's word that it was deleted can't be proved.
    func removeObject(_ id: UUID, ifLocalHash: String) async throws
    /// Items the person deleted here, kept until the server knows. Sync deletes from the server only
    /// on this record, never because a file is missing, so lost files come back instead of spreading.
    func deletedObjectIDs() async throws -> Set<UUID>
    func clearDeletion(_ id: UUID) async throws
    /// Both sides changed. The module keeps the older version as a copy unless nothing is lost by
    /// dropping it. It can run again after a failure, so that copy must not double up.
    func resolveConflict(local: SealedObject, remote: SealedObject) async throws -> ConflictResolution
    func emptyOldTrash() async throws
}

public struct RemoteRecord: Sendable, Equatable {
    public let id: UUID
    public let kind: ContentKind
    /// Nil when the item has been deleted.
    public let hash: String?
    public let byteCount: Int

    public init(id: UUID, kind: ContentKind, hash: String?, byteCount: Int) {
        self.id = id
        self.kind = kind
        self.hash = hash
        self.byteCount = byteCount
    }

    public var isDeleted: Bool { hash == nil }
}

public enum SyncError: Error, Equatable {
    /// The server's copy changed since this device last looked. The next sync sorts it out.
    case changedOnServer
    /// The item changed here while sync was working. The next sync sorts it out.
    case changedLocally
}

/// The server side of sync. Writes name the version they expect, so two devices can't overwrite each
/// other unseen.
public protocol SyncRemote: Sendable {
    func list() async throws -> [RemoteRecord]
    /// `reusing` is what this device has. If the body hasn't changed, it needn't be downloaded again.
    func fetch(_ id: UUID, reusing local: SealedObject?) async throws -> SealedObject?
    /// `expected` nil means the row doesn't exist yet. Tombstones are matched by `replacingDeleted`.
    func upload(_ object: SealedObject, expected: String?, replacingDeleted: Bool) async throws
    func delete(_ id: UUID, expected: String) async throws
}

/// What each item looked like the last time this device and the server agreed. It's how sync tells
/// "I changed this" from "they changed this". It holds only IDs and hashes of ciphertext.
public protocol SyncStateStore: Sendable {
    func load() throws -> [UUID: String]
    func save(_ state: [UUID: String]) throws
}

public struct FileSyncState: SyncStateStore {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() throws -> [UUID: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let stored = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    public func save(_ state: [UUID: String]) throws {
        let stored = Dictionary(uniqueKeysWithValues: state.map { ($0.key.uuidString, $0.value) })
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
    }
}

public struct SyncReport: Sendable, Equatable {
    public var uploaded = 0
    public var downloaded = 0
    public var removedHere = 0
    public var removedThere = 0
    public var conflicts = 0
    /// Items that couldn't sync this time. They're untouched here and tried again next time.
    public var failed = 0
    /// Items here or from the server that this device's key doesn't open. They're left as they are.
    public var rejected = 0
    /// Removals not applied, because one sync shouldn't empty a library without the person agreeing.
    public var heldRemovals = 0
    public var byteCount = 0

    public init() {}

    public var changedThisDevice: Bool {
        downloaded > 0 || removedHere > 0 || conflicts > 0
    }
}

/// Compares this device, the server, and what they last agreed on, and moves each item the right way.
/// State is saved after every item, so a crash just means picking up where it stopped.
public actor SyncEngine {
    /// More removals than this in one sync, and it stops to ask.
    private static let removalAllowance = 5
    private static let removalShare = 5

    private let areas: [any SyncArea]
    private let remote: any SyncRemote
    private let stateStore: any SyncStateStore

    public init(areas: [any SyncArea], remote: any SyncRemote, state: any SyncStateStore) {
        self.areas = areas
        self.remote = remote
        stateStore = state
    }

    private func area(for kind: ContentKind) -> (any SyncArea)? {
        areas.first { $0.kinds.contains(kind) }
    }

    public func sync(allowLargeRemoval: Bool = false) async throws -> SyncReport {
        var report = SyncReport()
        var agreed = try stateStore.load()
        let records = try await remote.list()
        let remoteByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        report.byteCount = records.reduce(0) { $0 + $1.byteCount }

        let holdRemovals = try await removalsNeedAsking(remoteByID, agreed: agreed, allowed: allowLargeRemoval, report: &report)

        var seen = Set<UUID>()
        for area in areas {
            let ids = Set(try await area.sealedObjectIDs()).union(try await area.deletedObjectIDs())
            for id in ids where seen.insert(id).inserted {
                await settle(id, here: area, remote: remoteByID[id], holdRemovals: holdRemovals, agreed: &agreed, report: &report)
            }
        }
        for record in records where !seen.contains(record.id) {
            guard let area = area(for: record.kind) else { continue }
            await settle(record.id, here: area, remote: record, holdRemovals: holdRemovals, agreed: &agreed, report: &report)
        }
        for area in areas { try? await area.emptyOldTrash() }
        return report
    }

    /// A server saying "these are deleted" can't be proved, and one bad migration could say it about
    /// everything. So an unusual number of removals waits for the person to agree.
    private func removalsNeedAsking(
        _ remoteByID: [UUID: RemoteRecord], agreed: [UUID: String], allowed: Bool, report: inout SyncReport
    ) async throws -> Bool {
        var removals = 0
        var total = 0
        for area in areas {
            for id in try await area.sealedObjectIDs() {
                total += 1
                if remoteByID[id]?.isDeleted == true, try await area.sealedHash(of: id) == agreed[id] { removals += 1 }
            }
        }
        guard !allowed, removals > max(Self.removalAllowance, total / Self.removalShare) else { return false }
        report.heldRemovals = removals
        return true
    }

    private func settle(
        _ id: UUID, here area: any SyncArea, remote record: RemoteRecord?, holdRemovals: Bool,
        agreed: inout [UUID: String], report: inout SyncReport
    ) async {
        do {
            let before = agreed[id]
            let local = try await area.sealedHash(of: id)
            // Read per item, because the person can delete something while sync is running.
            var deleted = try await area.deletedObjectIDs().contains(id)
            if deleted, local != nil {
                // It's here, so the record is out of date and mustn't act on this item later.
                try await area.clearDeletion(id)
                deleted = false
            }
            switch (local, record?.hash) {
            case (nil, nil):
                if record?.isDeleted == true || before == nil {
                    agreed[id] = nil
                    if deleted { try await area.clearDeletion(id) }
                }

            case (let local?, nil) where record?.isDeleted == true:
                if local == before {
                    if holdRemovals { return }
                    try await area.removeObject(id, ifLocalHash: local)
                    agreed[id] = nil
                    report.removedHere += 1
                } else {
                    // Edited here, deleted there. Losing the edit can't be undone, so the edit wins.
                    agreed[id] = try await push(id, in: area, expected: nil, replacingDeleted: true)
                    report.uploaded += 1
                }

            case (.some, nil):
                agreed[id] = try await push(id, in: area, expected: nil, replacingDeleted: false)
                report.uploaded += 1

            case (nil, let remote?):
                if deleted, remote == before {
                    try await self.remote.delete(id, expected: remote)
                    agreed[id] = nil
                    try await area.clearDeletion(id)
                    report.removedThere += 1
                } else {
                    // New, or edited elsewhere since the delete, or a file that went missing here.
                    // In all three, what the server has is worth keeping.
                    if deleted { try await area.clearDeletion(id) }
                    try await pull(id, into: area, ifLocalHash: nil, expected: remote)
                    agreed[id] = remote
                    report.downloaded += 1
                }

            case (let local?, let remote?):
                if local == remote {
                    agreed[id] = local
                } else if local == before {
                    try await pull(id, into: area, ifLocalHash: local, expected: remote)
                    agreed[id] = remote
                    report.downloaded += 1
                } else if remote == before {
                    do {
                        agreed[id] = try await push(id, in: area, expected: remote, replacingDeleted: false)
                        report.uploaded += 1
                    } catch is CryptoError {
                        // The change here is damage, not an edit. The server's copy puts it right.
                        try await pull(id, into: area, ifLocalHash: local, expected: remote)
                        agreed[id] = remote
                        report.downloaded += 1
                    }
                } else {
                    agreed[id] = try await settleConflict(id, in: area, localHash: local, expected: remote, report: &report)
                }
            }
            try stateStore.save(agreed)
        } catch is CryptoError {
            report.rejected += 1
        } catch {
            report.failed += 1
        }
    }

    private func push(_ id: UUID, in area: any SyncArea, expected: String?, replacingDeleted: Bool) async throws -> String {
        guard let object = try await area.verifiedObject(id) else { throw SyncError.changedLocally }
        try await remote.upload(object, expected: expected, replacingDeleted: replacingDeleted)
        return object.hash
    }

    private func pull(_ id: UUID, into area: any SyncArea, ifLocalHash: String?, expected: String) async throws {
        let incoming = try await fetch(id, from: area, expected: expected)
        try await area.store(incoming, ifLocalHash: ifLocalHash)
    }

    /// What arrives has to be what the list promised, or the list moved on and the next sync sorts it out.
    private func fetch(_ id: UUID, from area: any SyncArea, expected: String) async throws -> SealedObject {
        let local = try await area.sealedObject(id)
        guard let object = try await remote.fetch(id, reusing: local), object.hash == expected else {
            throw SyncError.changedOnServer
        }
        return object
    }

    private func settleConflict(
        _ id: UUID, in area: any SyncArea, localHash: String, expected: String, report: inout SyncReport
    ) async throws -> String {
        let incoming = try await fetch(id, from: area, expected: expected)
        let local: SealedObject
        do {
            guard let verified = try await area.verifiedObject(id) else { throw SyncError.changedLocally }
            local = verified
        } catch is CryptoError {
            try await area.store(incoming, ifLocalHash: localHash)
            report.downloaded += 1
            return incoming.hash
        }
        guard local.hash == localHash else { throw SyncError.changedLocally }
        let resolution = try await area.resolveConflict(local: local, remote: incoming)
        report.conflicts += 1
        switch resolution {
        case .keepLocal:
            try await remote.upload(local, expected: expected, replacingDeleted: false)
            return local.hash
        case .keepRemote:
            try await area.store(incoming, ifLocalHash: localHash)
            return incoming.hash
        }
    }
}
