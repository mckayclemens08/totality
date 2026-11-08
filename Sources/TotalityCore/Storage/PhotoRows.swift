import Foundation

/// One photo's row, as the server keeps it: an ID, the sealed details, and a size. Nothing in it can be
/// read without the content key.
public struct PhotoRow: Sendable, Equatable {
    public let id: UUID
    public let details: Data
    public let byteCount: Int

    public init(id: UUID, details: Data, byteCount: Int) {
        self.id = id
        self.details = details
        self.byteCount = byteCount
    }
}

/// The signed-in account isn't the one the rows were made for. Not a network problem: the library
/// closes, and nothing it kept is shown.
public struct PhotoRowsWrongAccount: Error, Equatable, Sendable {
    public init() {}
}

/// Where Photos keeps its rows, so Photos never needs to know about Supabase. The account is always the
/// signed-in one, and the database's row rules keep each account to its own.
public protocol PhotoRows: Sendable {
    /// Every live photo row of the signed-in account.
    func list() async throws -> [PhotoRow]
    /// Adds a photo's row, naming its original's blob. A row already there under this ID is an earlier
    /// try that landed, which is fine.
    func insert(_ row: PhotoRow, original: UUID) async throws
}
