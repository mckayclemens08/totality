import TotalityCore

/// Web's entry in the registry. Other modules can't attach bookmarks yet, and search inside Totality
/// doesn't reach them.
public struct WebModule: ContentHandler {
    public let module = ModuleID.web
    public let kinds: Set<ContentKind> = [.bookmark]

    public init() {}
}
