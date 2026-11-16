import CryptoKit
import Foundation
import Storage
import Supabase
import TotalityCore

/// Sync's server side. Content only ever crosses as ciphertext. The server does see each item's ID,
/// kind, size, and when it changed. Rows live in Supabase. Bodies live in the sealed store on the Oracle
/// server (issue 54), and older ones are read from Supabase Storage until `moveBodies` has moved them.
public struct SupabaseSyncRemote: SyncRemote, MovesBodies {
    private static let bucket = "content"
    private static let pageSize = 1000
    /// Far more than the free plan can hold, so reaching it means the server is misbehaving.
    private static let rowLimit = 500_000
    /// The sealed store's own ceiling for one blob, with room for the sealed details.
    static let objectLimit = SealedStoreClient.maxBlob + 1_048_576
    /// A body bigger than this is downloaded into a file, a piece at a time, never into memory whole.
    static let inMemoryLimit = 16 * 1024 * 1024

    private struct ListRow: Decodable {
        let id: UUID
        let kind: String
        let content_hash: String?
        let byte_size: Int?
        let deleted_at: String?
    }

    private struct ObjectRow: Decodable {
        let kind: String
        let meta_cipher: String?
        let storage_key: String?
        let byte_size: Int?
        let deleted_at: String?
    }

    private struct KeyRow: Decodable {
        let storage_key: String?
    }

    private struct Inserted: Decodable {
        let id: UUID
    }

    private let client: SupabaseClient
    private let account: String?
    private let bodies: SyncBodies
    /// Where big bodies land as they download. They're ciphertext, and the area that takes one moves it
    /// into place, so anything left here is from a sync that stopped and is cleared later.
    private let incoming: URL

    init(client: SupabaseClient, account: String? = nil, sealed: (any SealedStore)? = nil, incoming: URL? = nil) {
        self.client = client
        self.account = account
        let store = sealed ?? SealedStoreClient(token: { try await client.auth.session.accessToken })
        bodies = SyncBodies(bucket: SupabaseBucket(client: client, bucket: Self.bucket), sealed: store)
        self.incoming = incoming ?? FileManager.default.temporaryDirectory.appendingPathComponent("sync-incoming", isDirectory: true)
    }

    private init(client: SupabaseClient, account: String, bodies: SyncBodies, incoming: URL) {
        self.client = client
        self.account = account
        self.bodies = bodies
        self.incoming = incoming
    }

    public func forCurrentAccount() async throws -> any SyncRemote {
        Self.clearOldIncoming(in: incoming)
        return SupabaseSyncRemote(client: client, account: try await owner(), bodies: bodies, incoming: incoming)
    }

    /// Downloads more than a day old belong to a sync that's long over. A newer one is kept, so a big
    /// download that dropped carries on from where it got to.
    static func clearOldIncoming(in folder: URL, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in names {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > 24 * 60 * 60 { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Reads page by page, because the server stops at a page of its own otherwise, and an item that
    /// fell off the end would look new.
    public func list() async throws -> [RemoteRecord] {
        var records: [RemoteRecord] = []
        var offset = 0
        while true {
            let rows: [ListRow] = try await client.from("content_objects")
                .select("id, kind, content_hash, byte_size, deleted_at")
                .eq("owner_id", value: try await owner())
                .order("id")
                .range(from: offset, to: offset + Self.pageSize - 1)
                .execute()
                .value
            offset += rows.count
            records += rows.compactMap { row in
                guard let kind = ContentKind(rawValue: row.kind) else { return nil }
                if row.deleted_at != nil { return RemoteRecord(id: row.id, kind: kind, hash: nil, byteCount: 0) }
                // Only a real tombstone means deleted. A live row with no hash is broken, not gone.
                guard let hash = row.content_hash.flatMap(Self.hex) else { return nil }
                return RemoteRecord(id: row.id, kind: kind, hash: hash, byteCount: row.byte_size ?? 0)
            }
            if rows.count < Self.pageSize { return records }
            guard offset < Self.rowLimit else { throw AccountError.failed }
        }
    }

    public func fetch(_ id: UUID, reusing local: SealedObject?) async throws -> SealedObject? {
        let rows: [ObjectRow] = try await client.from("content_objects")
            .select("kind, meta_cipher, storage_key, byte_size, deleted_at")
            .eq("id", value: id.uuidString)
            .execute()
            .value
        guard let row = rows.first, row.deleted_at == nil, let kind = ContentKind(rawValue: row.kind),
              let meta = row.meta_cipher.flatMap(Self.bytes)
        else { return nil }
        guard (row.byte_size ?? 0) <= Self.objectLimit else { throw AccountError.failed }
        let owner = try await owner()
        guard let key = row.storage_key else { return SealedObject(id: id, kind: kind, meta: meta, body: nil) }
        if let local, let bodyHash = local.bodyHash, bodies.holds(key, owner: owner, item: id, bodyHash: bodyHash) {
            if let file = local.bodyFile { return SealedObject(id: id, kind: kind, meta: meta, bodyFile: file) }
            if let body = local.body { return SealedObject(id: id, kind: kind, meta: meta, body: body) }
        }
        let bodySize = max(0, (row.byte_size ?? 0) - meta.count)
        guard SealedBlobKey.isSealed(key), bodySize > Self.inMemoryLimit else {
            return SealedObject(id: id, kind: kind, meta: meta, body: try await bodies.read(key, owner: owner))
        }
        // Named for the key, which names the exact body, so a download that dropped carries on next time.
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let file = incoming.appendingPathComponent(SealedObject.fileName(forKey: key))
        try await bodies.download(key, owner: owner, to: file, limit: Self.objectLimit)
        let downloaded = SealedObject(id: id, kind: kind, meta: meta, bodyFile: try SealedFile(reading: file))
        // The key names the body by its hash, so a download that went wrong is thrown away, not resumed.
        guard let bodyHash = downloaded.bodyHash, bodies.holds(key, owner: owner, item: id, bodyHash: bodyHash) else {
            try? FileManager.default.removeItem(at: file)
            throw SealedStoreError.mismatch
        }
        return downloaded
    }

    /// Kinds whose whole content fits in the sealed metadata, so they have no body to store.
    static let metaOnly: Set<ContentKind> = [.event, .bookmark, .mailMarks, .mailSettings, .mailKeys, .mailOutside, .readerDrive, .readerPlaces]

    public func upload(_ object: SealedObject, expected: String?, replacingDeleted: Bool) async throws {
        if !Self.metaOnly.contains(object.kind), !object.hasBody { throw AccountError.failed }
        let owner = try await owner()
        let previous = try await currentKey(of: object.id)
        var key: String?
        if object.hasBody, let bodyHash = object.bodyHash {
            // Named for the body alone, so a change to the details doesn't move the whole file again.
            let path = bodies.key(owner: owner, item: object.id, bodyHash: bodyHash)
            if path != previous {
                if let file = object.bodyFile {
                    try await bodies.writeFile(file.url, at: path, owner: owner)
                } else if let body = object.body {
                    try await bodies.write(body, at: path, owner: owner)
                }
            }
            key = path
        }
        var row: [String: AnyJSON] = [
            "kind": .string(object.kind.rawValue),
            "storage_key": key.map(AnyJSON.string) ?? .null,
            "byte_size": .integer(object.meta.count + object.bodyCount),
            "content_hash": .string(Self.literal(try Self.hashBytes(object.hash))),
            "meta_cipher": .string(Self.literal(object.meta)),
            "deleted_at": .null,
        ]
        if expected == nil && !replacingDeleted {
            row["id"] = .string(object.id.uuidString)
            row["owner_id"] = .string(owner)
            row["key_ref"] = .string("crk:\(object.id.uuidString.lowercased())")
            do {
                try await client.from("content_objects").insert(row).execute()
            } catch let error as PostgrestError where error.code == "23505" {
                throw SyncError.changedOnServer
            }
        } else {
            row["kind"] = nil
            var update = try client.from("content_objects").update(row).eq("id", value: object.id.uuidString)
            if let expected {
                update = update.eq("content_hash", value: Self.literal(try Self.hashBytes(expected)))
            } else {
                update = update.not("deleted_at", operator: .is, value: "null")
            }
            let changed: [Inserted] = try await update.select("id").execute().value
            guard !changed.isEmpty else {
                // Another device may have landed the same body, so only clear it if nothing points at it.
                if let key, key != previous, try await currentKey(of: object.id) != key {
                    try? await bodies.remove(key, owner: owner)
                }
                throw SyncError.changedOnServer
            }
        }
        if let previous, previous != key {
            try? await bodies.remove(previous, owner: owner)
        }
    }

    public func delete(_ id: UUID, expected: String) async throws {
        _ = try await owner()
        let previous = try await currentKey(of: id)
        let tombstone: [String: AnyJSON] = [
            "deleted_at": .string(ISO8601DateFormatter().string(from: Date())),
            "meta_cipher": .null,
            "storage_key": .null,
            "content_hash": .null,
            "byte_size": .integer(0),
        ]
        let changed: [Inserted] = try await client.from("content_objects")
            .update(tombstone)
            .eq("id", value: id.uuidString)
            .eq("content_hash", value: Self.literal(try Self.hashBytes(expected)))
            .select("id")
            .execute()
            .value
        guard !changed.isEmpty else { throw SyncError.changedOnServer }
        if let previous { try? await bodies.remove(previous, owner: try await owner()) }
    }

    /// Moves some of the bodies still in Supabase Storage to the sealed store. `BodyMove` has the order
    /// that keeps every file safe if it stops partway.
    public func moveBodies() async throws -> BodyMoveReport {
        let owner = try await owner()
        return try await BodyMove(rows: SupabaseMovableRows(client: client, owner: owner), bodies: bodies, owner: owner).run()
    }

    /// Fails if the session changed partway through a sync, rather than writing as someone else.
    private func owner() async throws -> String {
        let current = try await client.auth.session.user.id.uuidString.lowercased()
        guard account == nil || account == current else { throw AccountError.failed }
        return current
    }

    private func currentKey(of id: UUID) async throws -> String? {
        let rows: [KeyRow] = try await client.from("content_objects")
            .select("storage_key")
            .eq("id", value: id.uuidString)
            .execute()
            .value
        return rows.first?.storage_key
    }

    static func literal(_ data: Data) -> String {
        "\\x" + data.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(_ literal: String) -> Data? {
        guard literal.hasPrefix("\\x"), literal.count % 2 == 0 else { return nil }
        var data = Data(capacity: literal.count / 2)
        var index = literal.index(literal.startIndex, offsetBy: 2)
        while index < literal.endIndex {
            let next = literal.index(index, offsetBy: 2)
            guard let byte = UInt8(literal[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func hex(_ literal: String) -> String? {
        literal.hasPrefix("\\x") ? String(literal.dropFirst(2)) : nil
    }

    private static func hashBytes(_ hash: String) throws -> Data {
        guard let data = bytes("\\x" + hash) else { throw AccountError.failed }
        return data
    }
}

/// Supabase Storage's `content` bucket.
struct SupabaseBucket: BucketStore {
    let client: SupabaseClient
    let bucket: String

    func download(_ path: String) async throws -> Data {
        try await client.storage.from(bucket).download(path: path)
    }

    func remove(_ path: String) async throws {
        _ = try await client.storage.from(bucket).remove(paths: [path])
    }
}

/// The rows `BodyMove` works through. Row-level security keeps every query to the signed-in account,
/// and each also names the owner.
struct SupabaseMovableRows: MovableRows {
    private struct Row: Decodable {
        let id: UUID
        let kind: String
        let storage_key: String?
        let content_hash: String?
        let meta_cipher: String?
    }

    private struct Changed: Decodable {
        let id: UUID
    }

    let client: SupabaseClient
    let owner: String

    func bucketRows(after: UUID?, limit: Int) async throws -> [BucketRow] {
        var query = client.from("content_objects")
            .select("id, kind, storage_key, content_hash, meta_cipher")
            .eq("owner_id", value: owner)
        if let after { query = query.gt("id", value: after.uuidString.lowercased()) }
        let rows: [Row] = try await query
            .is("deleted_at", value: nil)
            .not("storage_key", operator: .is, value: "null")
            .not("storage_key", operator: .like, value: "\(owner)/sealed/%")
            .order("id")
            .limit(limit)
            .execute()
            .value
        return rows.compactMap { row in
            guard let kind = ContentKind(rawValue: row.kind), let key = row.storage_key,
                  let hash = row.content_hash, hash.hasPrefix("\\x"),
                  let meta = row.meta_cipher.flatMap(SupabaseSyncRemote.bytes)
            else { return nil }
            return BucketRow(id: row.id, kind: kind, key: key, hash: String(hash.dropFirst(2)), meta: meta)
        }
    }

    func repoint(_ id: UUID, from oldKey: String, hash: String, to newKey: String) async throws -> Bool {
        guard let hashBytes = SupabaseSyncRemote.bytes("\\x" + hash) else { throw AccountError.failed }
        let changed: [Changed] = try await client.from("content_objects")
            .update(["storage_key": AnyJSON.string(newKey)])
            .eq("id", value: id.uuidString)
            .eq("owner_id", value: owner)
            .eq("storage_key", value: oldKey)
            .eq("content_hash", value: SupabaseSyncRemote.literal(hashBytes))
            .is("deleted_at", value: nil)
            .select("id")
            .execute()
            .value
        return !changed.isEmpty
    }

    func currentKey(of id: UUID) async throws -> String? {
        struct KeyRow: Decodable { let storage_key: String? }
        let rows: [KeyRow] = try await client.from("content_objects")
            .select("storage_key")
            .eq("id", value: id.uuidString)
            .execute()
            .value
        return rows.first?.storage_key
    }
}

extension SupabaseAccountService {
    public var syncRemote: SupabaseSyncRemote {
        SupabaseSyncRemote(client: client)
    }
}

extension SealedObject {
    /// A download's file name, from the key, which only ever holds letters, digits, `/`, `-` and `.`.
    static func fileName(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".incoming"
    }
}
