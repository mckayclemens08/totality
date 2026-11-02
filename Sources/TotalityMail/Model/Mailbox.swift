import Foundation

/// Where the list is looking. Starred isn't a folder: a starred message stays where it is.
public enum MailPlace: Hashable, Sendable {
    case folder(MailFolder)
    case starred

    public static let inbox = MailPlace.folder(.inbox)
    /// In the order the folder list shows them. The person's own folders follow.
    static let builtIn: [MailPlace] = [.inbox, .starred, .folder(.sent), .folder(.drafts), .folder(.archive), .folder(.spam), .folder(.trash)]

    /// Spam and Trash stand apart: their messages show only there, and everywhere else leaves them out.
    func shows(_ message: MailMessage) -> Bool {
        switch self {
        case .folder(.spam): message.marks.folder == .spam
        case .folder(.trash): message.marks.folder == .trash
        default: message.marks.folder != .spam && message.marks.folder != .trash
        }
    }

    func lists(_ message: MailMessage) -> Bool {
        switch self {
        case .folder(let folder): message.marks.folder == folder
        case .starred: message.marks.isStarred
        }
    }

    public var showsRecipients: Bool {
        self == .folder(.sent) || self == .folder(.drafts)
    }
}

/// What can be done to conversations. Each one can be undone, except deleting forever, which isn't here.
public enum MailAction: Hashable, Sendable {
    case archive, trash, reportSpam
    case move(MailFolder)
    case markRead, markUnread
    case star, unstar
}

/// What the person has set, kept sealed and synced like everything else.
public struct MailSettings: Hashable, Codable, Sendable {
    public var folders: [MailOwnFolder]
    public var blockedSenders: Set<String>
    public var alwaysLoadImages: Set<String>

    public init(folders: [MailOwnFolder] = [], blockedSenders: Set<String> = [], alwaysLoadImages: Set<String> = []) {
        self.folders = folders
        self.blockedSenders = blockedSenders
        self.alwaysLoadImages = alwaysLoadImages
    }
}

/// Everything this device holds, and every rule about it. Nothing here touches a disk or a network, so
/// the rules can be tested and any store can sit behind them.
public struct Mailbox: Sendable, Equatable {
    public static let trashLifetime: TimeInterval = 30 * 86_400

    public var address: String
    public var messages: [MailMessage]
    public var settings: MailSettings
    public var isFull: Bool

    public init(address: String = "", messages: [MailMessage] = [], settings: MailSettings = MailSettings(), isFull: Bool = false) {
        self.address = address
        self.messages = messages
        self.settings = settings
        self.isFull = isFull
    }

    public var places: [MailPlace] {
        MailPlace.builtIn + settings.folders.map { .folder(.own($0.id)) }
    }

    public func name(of place: MailPlace) -> String {
        switch place {
        case .starred: "Starred"
        case .folder(let folder): name(of: folder)
        }
    }

    public func name(of folder: MailFolder) -> String {
        switch folder {
        case .inbox: "Inbox"
        case .archive: "Archive"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .spam: "Spam"
        case .trash: "Trash"
        case .own(let id): settings.folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    /// Newest first. A query looks through everything in the place, so it runs here on the device.
    public func conversations(in place: MailPlace, matching query: String = "") -> [MailConversation] {
        let seen = messages.filter(place.shows)
        let listed = Set(seen.filter(place.lists).map(\.conversationID))
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Dictionary(grouping: seen.filter { listed.contains($0.conversationID) }, by: \.conversationID)
            .map { MailConversation(id: $0.key, messages: $0.value) }
            .filter { query.isEmpty || $0.matches(query) }
            // Two can share a date, and a row mustn't swap places between one look and the next.
            .sorted { ($0.latest.date, $0.id.uuidString) > ($1.latest.date, $1.id.uuidString) }
    }

    public func conversation(_ id: UUID, in place: MailPlace) -> MailConversation? {
        let seen = messages.filter { $0.conversationID == id && place.shows($0) }
        guard seen.contains(where: place.lists) else { return nil }
        return MailConversation(id: id, messages: seen)
    }

    public func unreadCount(in place: MailPlace) -> Int {
        conversations(in: place).filter { $0.messages.contains { place.lists($0) && $0.marks.isUnread } }.count
    }

    /// What an action changes, keyed by message. Sent mail and drafts stay put unless they're trashed,
    /// so archiving a conversation doesn't empty Sent.
    public func marks(after action: MailAction, on conversations: [MailConversation], now: Date) -> [UUID: MailMarks] {
        var changed: [UUID: MailMarks] = [:]
        for conversation in conversations {
            for message in conversation.messages {
                var marks = message.marks
                switch action {
                case .archive: Self.move(&marks, to: .archive, now: now)
                case .trash: Self.move(&marks, to: .trash, now: now)
                case .reportSpam: Self.move(&marks, to: .spam, now: now)
                case .move(let folder): Self.move(&marks, to: folder, now: now)
                case .markRead: marks.isUnread = false
                case .markUnread: if message.id == conversation.latest.id { marks.isUnread = true }
                case .star: if message.id == conversation.latest.id { marks.isStarred = true }
                case .unstar: marks.isStarred = false
                }
                if marks != message.marks { changed[message.id] = marks }
            }
        }
        return changed
    }

    private static func move(_ marks: inout MailMarks, to folder: MailFolder, now: Date) {
        if folder == .trash {
            guard marks.folder != .trash else { return }
            marks.trashedAt = now
            marks.trashedFrom = marks.folder
            marks.folder = .trash
            return
        }
        guard marks.folder != .sent, marks.folder != .drafts else { return }
        if marks.folder == .trash, let origin = marks.trashedFrom, origin == .sent || origin == .drafts {
            marks.folder = origin
        } else {
            marks.folder = folder
        }
        marks.trashedAt = nil
        marks.trashedFrom = nil
    }

    /// Moves what's already here from a blocked sender. New mail from them meets the same list on arrival.
    public func marksAfterBlocking(_ sender: MailAddress) -> [UUID: MailMarks] {
        var changed: [UUID: MailMarks] = [:]
        for message in messages where message.from.key == sender.key && message.marks.folder == .inbox {
            var marks = message.marks
            marks.folder = .spam
            changed[message.id] = marks
        }
        return changed
    }

    public mutating func apply(_ marks: [UUID: MailMarks]) {
        for index in messages.indices {
            if let changed = marks[messages[index].id] { messages[index].marks = changed }
        }
    }

    public mutating func remove(_ ids: Set<UUID>) {
        messages.removeAll { ids.contains($0.id) }
    }

    /// What's been in Trash for its full 30 days.
    public func expired(at now: Date) -> Set<UUID> {
        Set(messages.filter { message in
            guard message.marks.folder == .trash, let trashed = message.marks.trashedAt else { return false }
            return now.timeIntervalSince(trashed) >= Self.trashLifetime
        }.map(\.id))
    }

    /// A sender's standing choice only counts if the message proves it's from them, or anyone could
    /// borrow their address to see who opens a message. Nothing in Spam loads by itself.
    public func loadsImages(for message: MailMessage) -> Bool {
        message.proof == .proved && message.marks.folder != .spam
            && settings.alwaysLoadImages.contains(message.from.key)
    }
}
