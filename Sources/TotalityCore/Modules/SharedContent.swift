import Foundation

/// How one module's content travels inside a chat message, and what the chat shows for it. Messages and
/// Social never import each other: Social hands the app a `ShareRequest`, Messages sends `SharedContentLink`
/// text inside an end-to-end encrypted message, and the recipient's device asks the owning module what to show.
public enum SharedContentLink {
    private static let prefix = "totality://share/"

    /// The message text for a shared item. It holds only the module, kind and id, plus the author's handle so
    /// a placeholder can name whose post it is. Never a title, text, image or caption.
    public static func text(for ref: ContentRef, author: String? = nil) -> String {
        var text = "\(prefix)\(ref.module.rawValue)/\(ref.kind.rawValue)/\(ref.id.uuidString.lowercased())"
        if let author = author?.lowercased(), isHandle(author) { text += "?by=\(author)" }
        return text
    }

    /// What a message body is, if it is exactly one shared-item link. Anything else stays an ordinary message.
    public static func parse(_ body: String) -> Shared? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), !trimmed.contains(where: \.isWhitespace) else { return nil }
        let rest = trimmed.dropFirst(prefix.count)
        let halves = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = halves[0].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let module = ModuleID(rawValue: String(parts[0])),
              let kind = ContentKind(rawValue: String(parts[1])),
              let id = UUID(uuidString: String(parts[2])) else { return nil }
        var author: String?
        if halves.count == 2 {
            for pair in halves[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "by", isHandle(String(kv[1])) { author = String(kv[1]) }
            }
        }
        let ref = ContentRef(module: module, kind: kind, id: id, keyRef: .plain, preview: .init(title: "Shared \(kind.rawValue)"))
        return Shared(ref: ref, author: author)
    }

    /// The chat list's one line for a shared item, in place of the link.
    public static func summary(of body: String) -> String? {
        guard let shared = parse(body) else { return nil }
        return shared.ref.kind == .post ? "Shared a post" : "Shared an item"
    }

    private static func isHandle(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    public struct Shared: Equatable, Sendable {
        public let ref: ContentRef
        /// The author's handle, when the sender's phone included it.
        public let author: String?
    }
}

/// What the person pressed Share on, handed by the module to the app and on to Messages' picker.
public struct ShareRequest: Identifiable, Equatable, Sendable {
    public let ref: ContentRef
    public let author: String
    public let authorName: String
    /// The start of the post, for the picker's preview row on the sender's phone. It is never sent.
    public let snippet: String
    /// A web link, for public items only. Nil means Copy link is off, and why is `linkReason`.
    public let link: URL?
    public let linkReason: String?

    public var id: UUID { ref.id }

    public init(ref: ContentRef, author: String, authorName: String, snippet: String, link: URL?, linkReason: String?) {
        self.ref = ref
        self.author = author
        self.authorName = authorName
        self.snippet = snippet
        self.link = link
        self.linkReason = linkReason
    }

    /// The text that goes in the message.
    public var messageText: String { SharedContentLink.text(for: ref, author: author) }
}

public enum ShareLimits {
    /// Most chats one send can reach, to keep it from being used to spam.
    public static let maxTargets = 10

    /// The chats a send reaches: no repeats, and no more than the limit. Extra ones are dropped, never sent.
    public static func limited(_ targets: [String]) -> [String] {
        var seen = Set<String>()
        return Array(targets.filter { seen.insert($0).inserted }.prefix(maxTargets))
    }

    /// Send is on only with someone picked and within the limit.
    public static func canSend(selected: Int) -> Bool { selected > 0 && selected <= maxTargets }
}

/// What a shared item shows as, decided on the recipient's own device with the recipient's own access.
public enum SharedCardState: Equatable, Sendable {
    case card(SharedCardContent)
    /// This person can't open it: it may be limited to its author's friends or approved followers, or be gone.
    case unavailable(author: String?)
    /// It didn't load. Trying again may work.
    case failed
}

public struct SharedCardContent: Equatable, Sendable {
    public let authorName: String
    public let author: String
    public let audience: String
    public let text: String
    public let thumbnail: Data?
    public let likes: Int?
    public let comments: Int

    public init(authorName: String, author: String, audience: String, text: String, thumbnail: Data?, likes: Int?, comments: Int) {
        self.authorName = authorName
        self.author = author
        self.audience = audience
        self.text = text
        self.thumbnail = thumbnail
        self.likes = likes
        self.comments = comments
    }
}

/// How the app lets Messages draw and open a shared item without Messages knowing which module owns it.
public struct SharedContentHooks: Sendable {
    public let resolve: @Sendable @MainActor (ContentRef, _ author: String?) async -> SharedCardState
    /// Opens the item in its own module.
    public let open: @Sendable @MainActor (ContentRef) -> Void
    /// Opens a person's profile, for a placeholder's View profile.
    public let openAuthor: @Sendable @MainActor (String) -> Void

    public init(
        resolve: @escaping @Sendable @MainActor (ContentRef, _ author: String?) async -> SharedCardState,
        open: @escaping @Sendable @MainActor (ContentRef) -> Void,
        openAuthor: @escaping @Sendable @MainActor (String) -> Void
    ) {
        self.resolve = resolve
        self.open = open
        self.openAuthor = openAuthor
    }
}
