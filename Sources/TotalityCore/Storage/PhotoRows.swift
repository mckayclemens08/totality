import Foundation

/// One photo's row, as the server keeps it: an ID, the sealed details, and a size. Nothing in it can be
/// read without the content key.
public struct PhotoRow: Sendable, Equatable {
    public let id: UUID
    public let details: Data
    public let byteCount: Int
    /// When the server last changed it, by the server's clock. Nil when it isn't known.
    public let changed: Date?

    public init(id: UUID, details: Data, byteCount: Int, changed: Date? = nil) {
        self.id = id
        self.details = details
        self.byteCount = byteCount
        self.changed = changed
    }
}

/// The signed-in account isn't the one the rows were made for. Not a network problem: the library
/// closes, and nothing it kept is shown.
public struct PhotoRowsWrongAccount: Error, Equatable, Sendable {
    public init() {}
}

/// The two kinds of row Photos keeps: one per photo, and one per album.
public enum PhotoRowKind: Sendable, Equatable {
    case photo, album
}

/// Where Photos keeps its rows, so Photos never needs to know about Supabase. The account is always the
/// signed-in one, and the database's row rules keep each account to its own.
public protocol PhotoRows: Sendable {
    /// Every live row of this kind for the signed-in account.
    func list(_ kind: PhotoRowKind) async throws -> [PhotoRow]
    /// One row, or nil when it's gone.
    func row(_ id: UUID, kind: PhotoRowKind) async throws -> PhotoRow?
    /// Adds a row. A photo names its original's blob, and an album names none. A row already there
    /// under this ID with the same details is an earlier try that landed, which is fine.
    func insert(_ row: PhotoRow, kind: PhotoRowKind, original: UUID?) async throws
    /// Replaces a row's sealed details, only if they're still `old`. False when another device changed
    /// them first, or the row is gone.
    func update(_ row: PhotoRow, kind: PhotoRowKind, replacing old: Data) async throws -> Bool
    /// Removes a row for good. Harmless when it's already gone.
    func delete(_ id: UUID, kind: PhotoRowKind) async throws
}
