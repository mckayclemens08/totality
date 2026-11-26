import Foundation

/// Someone from the person's own Contacts, as another module sees them: what to call them, their photo and
/// how to reach them. It comes from sealed cards, so it stays in memory on this device and is never stored
/// or sent (issue 205, section 5).
public struct KnownPerson: Sendable, Hashable, Identifiable {
    /// The card's ID. Means something only to Contacts.
    public let id: UUID
    /// The name on the card, such as "Sam Okafor".
    public let name: String
    /// What the person calls them, such as "Mom", when the card has one.
    public let nickname: String?
    /// Lowercased email addresses, Totality Mail included.
    public let emails: [String]
    /// The Totality handle the card is linked to, lowercased, without the @.
    public let username: String?
    /// The card's photo: a small square JPEG rebuilt on this device by `SafeAvatar`.
    public let photo: Data?

    public init(id: UUID, name: String, nickname: String?, emails: [String], username: String?, photo: Data?) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.emails = emails.map { $0.lowercased() }
        self.username = username?.lowercased()
        self.photo = photo
    }

    /// What to call them: the nickname if there is one, else the name.
    public var shownName: String {
        guard let nickname, !nickname.trimmingCharacters(in: .whitespaces).isEmpty else { return name }
        return nickname
    }
}

/// Answers "who is this?" from the person's own Contacts, without anything leaving the device. Mail uses it
/// for sender names and address suggestions; Messages uses it for the nickname of someone in a chat. It's
/// synchronous and in memory, so a list can ask for every row as it draws.
public protocol PeopleLookup: Sendable {
    /// The card with this email address, matched without regard to case.
    func person(email: String) -> KnownPerson?
    /// The card linked to this Totality handle.
    func person(username: String) -> KnownPerson?
    /// Cards with an email address whose name, nickname or address starts with `typed`, best first.
    func people(matching typed: String, limit: Int) -> [KnownPerson]
}

/// A module that keeps a card for someone another module shows, such as Social's "Add to Contacts" on a
/// profile. Only the handle and the name shown cross over; the card is sealed like any other.
public protocol ContactMaker: ContentHandler {
    /// The card linked to `username`, made now if there isn't one. Returns it as a ref.
    func addContact(username: String, displayName: String?) async throws -> ContentRef
    /// Whether a card is already linked to `username`.
    func hasContact(username: String) async -> Bool
}

extension ModuleRegistry {
    /// The person's own Contacts, when that module is installed.
    public var people: (any PeopleLookup)? {
        handlers.lazy.compactMap { $0 as? any PeopleLookup }.first
    }

    /// The module that keeps cards for people, when it's installed.
    public var contactMaker: (any ContactMaker)? {
        handlers.lazy.compactMap { $0 as? any ContactMaker }.first
    }
}
