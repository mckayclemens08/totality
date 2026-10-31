import Foundation
import Storage
import Supabase
import TotalityCore

/// Sync's server side. Content only ever crosses as ciphertext. The server does see each item's ID,
/// kind, size, and when it changed.
public struct SupabaseSyncRemote: SyncRemote {
    private static let bucket = "content"
    private static let pageSize = 1000
    /// Far more than the free plan can hold, so reaching it means the server is misbehaving.
    private static let rowLimit = 500_000
    /// The bucket's own ceiling, with room for sealing.
    private static let objectLimit = 52_428_800 + 1_048_576

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

    init(client: SupabaseClient, account: String? = nil) {
        self.client = client
        self.account = account
    }

    public func forCurrentAccount() async throws -> any SyncRemote {
        SupabaseSyncRemote(client: client, account: try await owner())
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
        let body = try await row.storage_key.asyncMap { key -> Data in
            if let bodyHash = local?.bodyHash, let body = local?.body, key.hasSuffix("/\(bodyHash).body") { return body }
            return try await client.storage.from(Self.bucket).download(path: key)
        }
        return SealedObject(id: id, kind: kind, meta: meta, body: body)
    }

    public func upload(_ object: SealedObject, expected: String?, replacingDeleted: Bool) async throws {
        if object.kind != .event, object.body == nil { throw AccountError.failed }
        let owner = try await owner()
        let previous = try await currentKey(of: object.id)
        var key: String?
        if let body = object.body, let bodyHash = object.bodyHash {
            // Named for the body alone, so a change to the details doesn't move the whole file again.
            let path = "\(owner)/\(object.id.uuidString.lowercased())/\(bodyHash).body"
            if path != previous { try await store(body, at: path) }
            key = path
        }
        var row: [String: AnyJSON] = [
            "kind": .string(object.kind.rawValue),
            "storage_key": key.map(AnyJSON.string) ?? .null,
            "byte_size": .integer(object.meta.count + (object.body?.count ?? 0)),
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
                    _ = try? await client.storage.from(Self.bucket).remove(paths: [key])
                }
                throw SyncError.changedOnServer
            }
        }
        if let previous, previous != key {
            _ = try? await client.storage.from(Self.bucket).remove(paths: [previous])
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
        if let previous { _ = try? await client.storage.from(Self.bucket).remove(paths: [previous]) }
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

    /// The path is named for its contents, so finding it already there means an earlier try landed.
    private func store(_ body: Data, at path: String) async throws {
        do {
            _ = try await client.storage.from(Self.bucket).upload(
                path, data: body, options: FileOptions(contentType: "application/octet-stream")
            )
        } catch let error as StorageError where error.statusCode == "409" {
            return
        }
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

extension SupabaseAccountService {
    public var syncRemote: SupabaseSyncRemote {
        SupabaseSyncRemote(client: client)
    }
}

private extension Optional {
    func asyncMap<Result>(_ transform: (Wrapped) async throws -> Result) async rethrows -> Result? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
