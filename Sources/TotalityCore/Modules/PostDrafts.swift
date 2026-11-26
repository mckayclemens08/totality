import Foundation

/// A post another module asks Social to start, such as a hike from Hiking (issue 240). Nothing is posted
/// until the person presses Post in Social's composer, where they also pick who sees it. The app hands the
/// draft over, so the two modules never import each other.
public struct PostDraft: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String
    /// A JPEG to attach, like a picture of the route. Nil means text only.
    public var image: Data?
    /// What the draft is about, for the module that made it.
    public var source: ContentRef

    public init(id: UUID = UUID(), title: String, body: String, image: Data? = nil, source: ContentRef) {
        self.id = id
        self.title = title
        self.body = body
        self.image = image
        self.source = source
    }
}
