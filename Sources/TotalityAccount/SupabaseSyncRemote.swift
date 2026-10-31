import Foundation
import Storage
import Supabase
import TotalityCore

/// Sync's server side. Every value here is ciphertext, an ID, or a size.
public struct SupabaseSyncRemote: SyncRemote {
    private static let bucket = "content"
    private static let pageSize = 1000

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
        let deleted_at: String?
    }

    private struct KeyRow: Decodable {
        let storage_key: String?
    }

    private struct Inserted: Decodable {
        let id: UUID
    }

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// Reads page by page, because the server stops at a page of its own otherwise, and an item that
    /// fell off the end would look new.
    public func list() async throws -> [RemoteRecord] {
        var records: [RemoteRecord] = []
        while true {
            let rows: [ListRow] = try await client.from("content_objects")
                .select("id, kind, content_hash, byte_size, deleted_at")
                .eq("owner_id", value: try await owner())
                .order("id")
                .range(from: records.count, to: records.count + Self.pageSize - 1)
                .execute()
                .value
            records += rows.compactMap { row in
                guard let kind = ContentKind(rawValue: row.kind) else { return nil }
                let hash = row.deleted_at == nil ? row.content_hash.flatMap(Self.hex) : nil
                return RemoteRecord(id: row.id, kind: kind, hash: hash, byteCount: row.byte_size ?? 0)
            }
            if rows.count < Self.pageSize { return records }
        }
    }

    public func fetch(_ id: UUID) async throws -> SealedObject? {
        let rows: [ObjectRow] = try await client.from("content_objects")
            .select("kind, meta_cipher, storage_key, deleted_at")
            .eq("id", value: id.uuidString)
            .execute()
            .value
        guard let row = rows.first, row.deleted_at == nil, let kind = ContentKind(rawValue: row.kind),
              let meta = row.meta_cipher.flatMap(Self.bytes)
        else { return nil }
        let body = try await row.storage_key.asyncMap { try await client.storage.from(Self.bucket).download(path: $0) }
        return SealedObject(id: id, kind: kind, meta: meta, body: body)
    }

    public func upload(_ object: SealedObject, expected: String?, replacingDeleted: Bool) async throws {
        let owner = try await owner()
        let previous = try await currentKey(of: object.id)
        var key: String?
        if let body = object.body {
            let path = "\(owner)/\(object.id.uuidString.lowercased())/\(object.hash).body"
            try await store(body, at: path)
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
                if let key, key != previous { _ = try? await client.storage.from(Self.bucket).remove(paths: [key]) }
                throw SyncError.changedOnServer
            }
        }
        if let previous, previous != key {
            _ = try? await client.storage.from(Self.bucket).remove(paths: [previous])
        }
    }

    public func delete(_ id: UUID, expected: String) async throws {
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

    private func owner() async throws -> String {
        try await client.auth.session.user.id.uuidString.lowercased()
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
