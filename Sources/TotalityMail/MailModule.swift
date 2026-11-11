import TotalityCore

/// Mail's entry in the registry. It takes nothing from other modules yet, and search inside Totality
/// doesn't reach it. Saving an attachment goes the other way, to whichever module receives files.
///
/// It refreshes ahead: the app fetches mail before Mail is opened, so it's already there.
public struct MailModule: ModuleRefresher {
    public let module = ModuleID.mail
    public let kinds: Set<ContentKind> = []
    private let refresh: @Sendable () async -> Void

    /// `refresh` brings the signed-in account's mailbox up to date.
    public init(refresh: @escaping @Sendable () async -> Void = {}) {
        self.refresh = refresh
    }

    public func refreshAhead() async {
        await refresh()
    }
}

/// Mail in the home search. It reads the mailbox already open on this device, whichever account holds the key.
public struct MailSearcher: ModuleSearcher {
    public let module = ModuleID.mail
    public let kinds: Set<ContentKind> = []
    private let find: @Sendable (String) async -> [SearchHit]

    public init(model: MailAccountModel) {
        find = { query in await model.current.searchHits(query) }
    }

    public func search(_ query: String) async throws -> [SearchHit] { await find(query) }
}
