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

    private struct Row: Decodable {
        let id: UUID
        let meta_cipher: String?
        let byte_size: Int?
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

    public func list() async throws -> [PhotoRow] {
        let owner = try await owner()
        var found: [PhotoRow] = []
        var offset = 0
        while true {
            let rows: [Row] = try await client.from("content_objects")
                .select("id, meta_cipher, byte_size")
                .eq("owner_id", value: owner)
                .eq("kind", value: ContentKind.photo.rawValue)
                .is("deleted_at", value: nil)
                .order("id")
                .range(from: offset, to: offset + Self.pageSize - 1)
                .execute()
                .value
            offset += rows.count
            found += rows.compactMap { row in
                guard let details = row.meta_cipher.flatMap(SupabaseSyncRemote.bytes) else { return nil }
                return PhotoRow(id: row.id, details: details, byteCount: max(0, row.byte_size ?? 0))
            }
            if rows.count < Self.pageSize { return found }
            guard offset < Self.rowLimit else { throw AccountError.failed }
        }
    }

    public func insert(_ row: PhotoRow, original: UUID) async throws {
        let owner = try await owner()
        let hash = Data(SHA256.hash(data: row.details))
        let values: [String: AnyJSON] = [
            "id": .string(row.id.uuidString),
            "owner_id": .string(owner),
            "kind": .string(ContentKind.photo.rawValue),
            "key_ref": .string("crk:\(row.id.uuidString.lowercased())"),
            "storage_key": .string(SealedBlobKey.key(owner: owner, blob: original)),
            "byte_size": .integer(row.byteCount),
            "content_hash": .string(SupabaseSyncRemote.literal(hash)),
            "meta_cipher": .string(SupabaseSyncRemote.literal(row.details)),
        ]
        do {
            try await client.from("content_objects").insert(values).execute()
        } catch let error as PostgrestError where error.code == "23505" {
            // Already there from an earlier try, as long as it's this photo and it's ours.
            let existing: [Row] = try await client.from("content_objects")
                .select("id, meta_cipher, byte_size")
                .eq("id", value: row.id.uuidString)
                .eq("owner_id", value: owner)
                .execute()
                .value
            guard existing.first?.meta_cipher.flatMap(SupabaseSyncRemote.bytes) == row.details else { throw AccountError.failed }
        }
    }
}

extension SupabaseAccountService {
    /// Photos' rows for one account, which refuse to work under any other sign-in.
    public func photoRows(for account: String) -> SupabasePhotoRows {
        SupabasePhotoRows(client: client, account: account)
    }
}
