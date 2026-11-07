import Foundation
import TotalityCore

/// Supabase Storage's `content` bucket, as sync's bodies reach it. New bodies never go here any more
/// (issue 54): it's read from until everything has moved to the sealed store, and emptied as things move.
public protocol BucketStore: Sendable {
    func download(_ path: String) async throws -> Data
    func remove(_ path: String) async throws
}

/// Where an item's sealed body lives, chosen by the row's storage key. Every new body goes to the sealed
/// store. A key that still names a bucket path is read from the bucket, so nothing is unreadable while
/// the move is under way.
public struct SyncBodies: Sendable {
    let bucket: any BucketStore
    let sealed: any SealedStore

    public init(bucket: any BucketStore, sealed: any SealedStore) {
        self.bucket = bucket
        self.sealed = sealed
    }

    /// The key a body is stored under. The same body always gets the same key, so changing only an
    /// item's details never moves its file again.
    public func key(owner: String, item: UUID, bodyHash: String) -> String {
        SealedBlobKey.key(owner: owner, blob: SealedBlobKey.blob(owner: owner, item: item, bodyHash: bodyHash))
    }

    /// Whether `key` is where this exact body is kept, so a copy already on the device can be used.
    public func holds(_ key: String, owner: String, item: UUID, bodyHash: String) -> Bool {
        key == self.key(owner: owner, item: item, bodyHash: bodyHash) || (!SealedBlobKey.isSealed(key) && key.hasSuffix("/\(bodyHash).body"))
    }

    /// The bytes under a key. A row that names a blob the store doesn't have is an error, never an empty
    /// item, so a missing file can't pass for a deleted one.
    public func read(_ key: String, owner: String) async throws -> Data {
        if SealedBlobKey.isSealed(key) {
            guard let blob = SealedBlobKey.blob(in: key, owner: owner) else { throw AccountError.failed }
            guard let data = try await sealed.get(blob) else { throw SealedStoreError.unavailable }
            return data
        }
        return try await bucket.download(key)
    }

    public func write(_ body: Data, at key: String, owner: String) async throws {
        guard let blob = SealedBlobKey.blob(in: key, owner: owner) else { throw AccountError.failed }
        try await sealed.put(body, as: blob)
    }

    public func remove(_ key: String, owner: String) async throws {
        if SealedBlobKey.isSealed(key) {
            guard let blob = SealedBlobKey.blob(in: key, owner: owner) else { return }
            try await sealed.delete(blob)
        } else {
            try await bucket.remove(key)
        }
    }
}

/// A live row whose body is still in the bucket.
public struct BucketRow: Sendable, Equatable {
    public let id: UUID
    public let kind: ContentKind
    public let key: String
    public let hash: String
    public let meta: Data

    public init(id: UUID, kind: ContentKind, key: String, hash: String, meta: Data) {
        self.id = id
        self.kind = kind
        self.key = key
        self.hash = hash
        self.meta = meta
    }
}

/// The rows the move reads and changes, so tests can stand in for the database.
public protocol MovableRows: Sendable {
    /// Some of this account's live rows whose body is still in the bucket, at most `limit`.
    func bucketRows(limit: Int) async throws -> [BucketRow]
    /// Points the row at `newKey`, only if it still has `oldKey` and `hash`. Returns whether it did.
    func repoint(_ id: UUID, from oldKey: String, hash: String, to newKey: String) async throws -> Bool
    func currentKey(of id: UUID) async throws -> String?
}

public struct BodyMoveReport: Sendable, Equatable {
    public var moved = 0
    /// Rows left in the bucket this time: damaged there, or changed by another device meanwhile.
    public var left = 0

    public init(moved: Int = 0, left: Int = 0) {
        self.moved = moved
        self.left = left
    }
}

/// Moves bodies from the bucket to the sealed store, one item at a time, in an order that loses nothing
/// whenever it stops (issue 54):
///
/// 1. The bucket's copy is read, and has to match the row's hash, so a damaged copy is never moved.
/// 2. It's stored in the sealed store, which only finishes a blob whose size and SHA-256 match.
/// 3. It's read back from the sealed store and compared byte for byte.
/// 4. Only then is the row pointed at it, and only if the row hasn't changed meanwhile.
/// 5. Only then is the bucket's copy removed.
///
/// If the Oracle server is unreachable at any step, the move stops there and the row still names the
/// bucket's copy, which is still there. The next run starts that item again.
public struct BodyMove: Sendable {
    /// Items moved per run, so a sync isn't held up for long.
    public static let batch = 25

    let rows: any MovableRows
    let bodies: SyncBodies
    let owner: String

    public init(rows: any MovableRows, bodies: SyncBodies, owner: String) {
        self.rows = rows
        self.bodies = bodies
        self.owner = owner
    }

    public func run(limit: Int = BodyMove.batch) async throws -> BodyMoveReport {
        var report = BodyMoveReport()
        for row in try await rows.bucketRows(limit: limit) {
            try Task.checkCancellation()
            // Only this account's own bucket files, which is all the database lets a row name.
            guard row.key.hasPrefix("\(owner)/"), !SealedBlobKey.isSealed(row.key) else {
                report.left += 1
                continue
            }
            let body = try await bodies.bucket.download(row.key)
            let object = SealedObject(id: row.id, kind: row.kind, meta: row.meta, body: body)
            guard object.hash == row.hash, let bodyHash = object.bodyHash else {
                report.left += 1
                continue
            }
            let key = bodies.key(owner: owner, item: row.id, bodyHash: bodyHash)
            try await bodies.write(body, at: key, owner: owner)
            guard try await bodies.read(key, owner: owner) == body else { throw SealedStoreError.mismatch }
            guard try await rows.repoint(row.id, from: row.key, hash: row.hash, to: key) else {
                // Another device changed the item meanwhile. The blob stays only if the row now uses it.
                if try await rows.currentKey(of: row.id) != key { try? await bodies.remove(key, owner: owner) }
                report.left += 1
                continue
            }
            // The row no longer names it, so a failure here only leaves a stray file in the bucket.
            try? await bodies.bucket.remove(row.key)
            report.moved += 1
        }
        return report
    }
}

/// Sync remotes that can move their old bodies over. The app runs this after a sync that finished.
public protocol MovesBodies: Sendable {
    func moveBodies() async throws -> BodyMoveReport
}
