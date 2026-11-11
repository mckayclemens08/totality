import TotalityCore

/// Web's entry in the registry. Other modules can't attach bookmarks yet, and search inside Totality
/// doesn't reach them.
public struct WebModule: ContentHandler {
    public let module = ModuleID.web
    public let kinds: Set<ContentKind> = [.bookmark]
    private let refresh: @Sendable () async -> Void

    /// `refresh` brings bookmarks up to date, quietly.
    public init(refresh: @escaping @Sendable () async -> Void = {}) {
        self.refresh = refresh
    }
}

/// The app keeps this module fresh before it's opened, through `AppRefresh`, without showing it.
extension WebModule: ModuleRefresher {
    public func refreshAhead() async {
        await refresh()
    }
}

