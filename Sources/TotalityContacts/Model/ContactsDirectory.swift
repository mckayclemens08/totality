import Foundation
import TotalityCore

/// The cards as other modules may ask about them, through `PeopleLookup`: in memory only, filled from the
/// sealed cards once they're open, and emptied when the key closes. Nothing here is written anywhere.
public final class ContactsDirectory: PeopleLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var byEmail: [String: KnownPerson] = [:]
    private var byUsername: [String: KnownPerson] = [:]
    private var everyone: [KnownPerson] = []

    public init() {}

    /// Replaces what's known with these cards. Recently Deleted cards aren't known.
    public func update(_ cards: [ContactCard]) {
        let people = cards.filter { !$0.isDeleted }.sorted { $0.sortKey < $1.sortKey }.map(\.known)
        var emails: [String: KnownPerson] = [:], usernames: [String: KnownPerson] = [:]
        for person in people {
            for email in person.emails where emails[email] == nil { emails[email] = person }
            if let name = person.username, usernames[name] == nil { usernames[name] = person }
        }
        lock.withLock {
            everyone = people
            byEmail = emails
            byUsername = usernames
        }
    }

    public func clear() {
        update([])
    }

    public func person(email: String) -> KnownPerson? {
        let key = email.trimmingCharacters(in: .whitespaces).lowercased()
        return lock.withLock { byEmail[key] }
    }

    public func person(username: String) -> KnownPerson? {
        var key = username.trimmingCharacters(in: .whitespaces).lowercased()
        if key.hasPrefix("@") { key.removeFirst() }
        return lock.withLock { byUsername[key] }
    }

    public func people(matching typed: String, limit: Int) -> [KnownPerson] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, limit > 0 else { return [] }
        let all = lock.withLock { everyone }
        func starts(_ text: String) -> Bool {
            let lower = text.lowercased()
            return lower.hasPrefix(query) || lower.split(whereSeparator: { $0.isWhitespace || $0 == "." }).contains { $0.hasPrefix(query) }
        }
        return Array(all.filter { person in
            !person.emails.isEmpty && (starts(person.name) || person.nickname.map(starts) == true || person.emails.contains { $0.hasPrefix(query) })
        }.prefix(limit))
    }
}
