import Foundation
import TotalityCore

public enum ContactsModuleError: Error, Equatable {
    case unavailable, invalidUsername
}

/// Contacts' entry in the registry (issue 205, section 5). It meets other modules only here: search,
/// refs, birthdays for the Calendar, `PeopleLookup` for Mail and Messages, and Social's Add to Contacts.
public struct ContactsModule: ContentHandler {
    public let module = ModuleID.contacts
    public let kinds: Set<ContentKind> = [.contact]
    private let vault: ContactVault?
    private let directory: ContactsDirectory
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date
    private let refresh: @Sendable () async -> Void
    private let changed: @Sendable () async -> Void

    /// `refresh` brings Contacts up to date, quietly. `changed` tells Contacts' screens that another module
    /// added a card, so they read it in.
    public init(
        vault: ContactVault?, directory: ContactsDirectory,
        calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
        now: @escaping @Sendable () -> Date = { Date() },
        refresh: @escaping @Sendable () async -> Void = {}, changed: @escaping @Sendable () async -> Void = {}
    ) {
        self.vault = vault
        self.directory = directory
        self.calendar = calendar
        self.now = now
        self.refresh = refresh
        self.changed = changed
    }

    private func live() async -> [ContactCard] {
        guard let vault, let listing = try? await vault.everything() else { return [] }
        return listing.cards.filter { !$0.isDeleted }
    }

    static func ref(_ card: ContactCard) -> ContentRef {
        ContentRef(module: .contacts, kind: .contact, id: card.id, keyRef: .crk(objectID: card.id), preview: .init(title: card.shownName))
    }
}

/// Reads only the sealed cards on this device. Nothing searched for is kept or sent.
extension ContactsModule: ModuleSearcher {
    public func search(_ query: String) async throws -> [SearchHit] {
        let terms = SearchText.terms(in: query)
        guard !terms.isEmpty else { return [] }
        let cards = await live()
        try Task.checkCancellation()
        let calendar = calendar()
        return cards.filter { ContactSearch.matches($0, terms: terms) }
            .sorted { $0.sortKey < $1.sortKey }
            .map { card in
                let line = ContactSearch.summary(card, upcoming: nil, calendar: calendar).text
                return SearchHit(module: .contacts, itemID: card.id.uuidString, title: card.shownName, detail: line.isEmpty ? nil : line)
            }
    }
}

extension ContactsModule: ModuleRefresher {
    public func refreshAhead() async {
        await refresh()
    }
}

/// A card can be attached elsewhere through a ref, such as to a task. The ref carries the name shown and
/// nothing else from the card.
extension ContactsModule: ContentProvider {
    public func attachable() async throws -> [ContentRef] {
        await live().sorted { $0.sortKey < $1.sortKey }.map(Self.ref)
    }

    public func current(_ ref: ContentRef) async throws -> ContentRef? {
        guard ref.kind == .contact, let vault, let card = try? await vault.card(ref.id), !card.isDeleted else { return nil }
        return Self.ref(card)
    }
}

/// Birthdays show on the Calendar on their day, as all-day items (issue 205, section 5). Only the title
/// and the age cross over.
extension ContactsModule: AgendaProvider {
    public func agenda(from start: Date, to end: Date) async -> [AgendaItem] {
        Birthdays.agenda(await live(), from: start, to: end, in: calendar())
    }
}

/// Mail and Messages ask who someone is, from memory.
extension ContactsModule: PeopleLookup {
    public func person(email: String) -> KnownPerson? { directory.person(email: email) }
    public func person(username: String) -> KnownPerson? { directory.person(username: username) }
    public func people(matching typed: String, limit: Int) -> [KnownPerson] { directory.people(matching: typed, limit: limit) }
}

/// Social's "Add to Contacts" on a profile. Only the handle and the name shown come over.
extension ContactsModule: ContactMaker {
    public func addContact(username: String, displayName: String?) async throws -> ContentRef {
        guard let vault else { throw ContactsModuleError.unavailable }
        guard let handle = ContactCard.normalizedHandle(username) else { throw ContactsModuleError.invalidUsername }
        if let existing = await live().first(where: { $0.username == handle }) { return Self.ref(existing) }
        let card = ContactsModule.card(username: handle, displayName: displayName, at: now())
        try await vault.save(card)
        await changed()
        return Self.ref(card)
    }

    public func hasContact(username: String) async -> Bool {
        guard let handle = ContactCard.normalizedHandle(username) else { return false }
        return await live().contains { $0.username == handle }
    }

    /// A new card for someone on Totality: their display name split into given and family, and the link.
    static func card(username: String, displayName: String?, at now: Date) -> ContactCard {
        let shown = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = shown.split(separator: " ", maxSplits: 1).map(String.init)
        return ContactCard(
            givenName: words.first ?? username, familyName: words.count > 1 ? words[1] : "",
            username: username, createdAt: now
        )
    }
}
