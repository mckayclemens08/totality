import CryptoKit
import Foundation
import Supabase
import TotalityCore

/// Photos' rows in `content_objects`, one per photo, kind `photo`. A row holds the sealed details, the
/// original's sealed-store key, and the size, and nothing readable (issue 54). The row-level rules keep
/// each account to its own, and every query also names the signed-in owner. Sync leaves these rows alone,
/// because no sync area handles photos.
public struct SupabasePhotoRows: PhotoRows {
    private static let pageSize = 1000
    /// Far more than any free-plan library, so reaching it means the server is misbehaving.
    private static let rowLimit = 500_000

    private struct Changed: Decodable {
        let id: UUID
    }

    private struct Row: Decodable {
        let id: UUID
        let meta_cipher: String?
        let byte_size: Int?
        let updated_at: String?

        var photoRow: PhotoRow? {
            guard let details = meta_cipher.flatMap(SupabaseSyncRemote.bytes) else { return nil }
            return PhotoRow(id: id, details: details, byteCount: max(0, byte_size ?? 0), changed: updated_at.flatMap(Row.date))
        }

        static func date(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
    }

    private let client: SupabaseClient
    private let account: String

    init(client: SupabaseClient, account: String) {
        self.client = client
        self.account = account.lowercased()
    }

    /// Fails unless the signed-in account is the one these rows were made for, so a photo can never be
    /// listed or added under someone else's sign-in.
    private func owner() async throws -> String {
        let current = try await client.auth.session.user.id.uuidString.lowercased()
        guard current == account else { throw PhotoRowsWrongAccount() }
        return current
    }

    /// The sign-in token for the sealed store, held to the same account.
    public func accessToken() async throws -> String {
        let session = try await client.auth.session
        guard session.user.id.uuidString.lowercased() == account else { throw PhotoRowsWrongAccount() }
        return session.accessToken
    }

    private static func kind(_ kind: PhotoRowKind) -> String {
        switch kind {
        case .photo: ContentKind.photo.rawValue
        case .album: ContentKind.photoAlbum.rawValue
        }
    }

    private static func hash(_ details: Data) -> String {
        SupabaseSyncRemote.literal(Data(SHA256.hash(data: details)))
    }

    public func list(_ kind: PhotoRowKind) async throws -> [PhotoRow] {
        let owner = try await owner()
        var found: [PhotoRow] = []
        var offset = 0
        while true {
            let rows: [Row] = try await client.from("content_objects")
                .select("id, meta_cipher, byte_size, updated_at")
                .eq("owner_id", value: owner)
                .eq("kind", value: Self.kind(kind))
                .is("deleted_at", value: nil)
                .order("id")
                .range(from: offset, to: offset + Self.pageSize - 1)
                .execute()
                .value
            offset += rows.count
            found += rows.compactMap(\.photoRow)
            if rows.count < Self.pageSize { return found }
            guard offset < Self.rowLimit else { throw AccountError.failed }
        }
    }

    public func row(_ id: UUID, kind: PhotoRowKind) async throws -> PhotoRow? {
        let owner = try await owner()
        let rows: [Row] = try await client.from("content_objects")
            .select("id, meta_cipher, byte_size, updated_at")
            .eq("id", value: id.uuidString)
            .eq("owner_id", value: owner)
            .eq("kind", value: Self.kind(kind))
            .is("deleted_at", value: nil)
            .execute()
            .value
        return rows.first?.photoRow
    }

    public func insert(_ row: PhotoRow, kind: PhotoRowKind, original: UUID?) async throws {
        let owner = try await owner()
        var values: [String: AnyJSON] = [
            "id": .string(row.id.uuidString),
            "owner_id": .string(owner),
            "kind": .string(Self.kind(kind)),
            "key_ref": .string("crk:\(row.id.uuidString.lowercased())"),
            "byte_size": .integer(row.byteCount),
            "content_hash": .string(Self.hash(row.details)),
            "meta_cipher": .string(SupabaseSyncRemote.literal(row.details)),
        ]
        if let original { values["storage_key"] = .string(SealedBlobKey.key(owner: owner, blob: original)) }
        do {
            try await client.from("content_objects").insert(values).execute()
        } catch let error as PostgrestError where error.code == "23505" {
            // Already there from an earlier try, as long as it's this row and it's ours.
            let existing: [Row] = try await client.from("content_objects")
                .select("id, meta_cipher, byte_size, updated_at")
                .eq("id", value: row.id.uuidString)
                .eq("owner_id", value: owner)
                .eq("kind", value: Self.kind(kind))
                .execute()
                .value
            guard existing.first?.meta_cipher.flatMap(SupabaseSyncRemote.bytes) == row.details else { throw AccountError.failed }
        }
    }

    public func update(_ row: PhotoRow, kind: PhotoRowKind, replacing old: Data) async throws -> Bool {
        let owner = try await owner()
        let values: [String: AnyJSON] = [
            "meta_cipher": .string(SupabaseSyncRemote.literal(row.details)),
            "content_hash": .string(Self.hash(row.details)),
            "byte_size": .integer(row.byteCount),
        ]
        let changed: [Changed] = try await client.from("content_objects")
            .update(values)
            .eq("id", value: row.id.uuidString)
            .eq("owner_id", value: owner)
            .eq("kind", value: Self.kind(kind))
            .eq("content_hash", value: Self.hash(old))
            .select("id")
            .execute()
            .value
        return !changed.isEmpty
    }

    public func delete(_ id: UUID, kind: PhotoRowKind) async throws {
        let owner = try await owner()
        try await client.from("content_objects")
            .delete()
            .eq("id", value: id.uuidString)
            .eq("owner_id", value: owner)
            .eq("kind", value: Self.kind(kind))
            .execute()
    }
}

extension SupabaseAccountService {
    /// Photos' rows for one account, which refuse to work under any other sign-in.
    public func photoRows(for account: String) -> SupabasePhotoRows {
        SupabasePhotoRows(client: client, account: account)
    }
}
