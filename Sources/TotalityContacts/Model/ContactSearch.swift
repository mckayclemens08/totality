import Foundation
import TotalityCore

/// Search across names, numbers, addresses and notes, on the device (issue 205, section 2). Every word has
/// to match somewhere on the card, as everywhere in Totality. A word with digits in it also matches a phone
/// number however it's written, so "5550142" finds "(801) 555-0142".
public enum ContactSearch {
    public static func matches(_ card: ContactCard, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = searchable(card)
        let numbers = card.phones.map { digits($0.value) }
        return terms.allSatisfy { term in
            if SearchText.find(term, in: text) != nil { return true }
            let wanted = digits(term)
            return wanted.count >= 3 && numbers.contains { $0.contains(wanted) }
        }
    }

    public static func filter(_ cards: [ContactCard], query: String) -> [ContactCard] {
        let terms = SearchText.terms(in: query)
        return cards.filter { matches($0, terms: terms) }
    }

    static func searchable(_ card: ContactCard) -> String {
        var parts = [card.givenName, card.familyName, card.nickname, card.company, card.notes, card.username ?? ""]
        parts += card.phones.map(\.value) + card.emails.map(\.value) + card.addresses.map(\.oneLine) + card.labels
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func digits(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }

    /// The quiet line under a name in the list, as on the approved canvas: the @username when linked, a
    /// birthday this week, the company, or what the card holds.
    public static func summary(_ card: ContactCard, upcoming: Birthdays.Upcoming?, calendar: Calendar) -> (text: String, isLink: Bool) {
        if let handle = card.handle { return ("\(handle) on Totality", true) }
        if let upcoming, upcoming.daysAway < 7 {
            let when = Birthdays.when(upcoming, in: calendar)
            return ("Birthday \(when)", false)
        }
        let company = card.company.trimmingCharacters(in: .whitespaces)
        if !company.isEmpty { return (company, false) }
        var parts: [String] = []
        var seen = Set<String>()
        for label in card.phones.map(\.label) where seen.insert(label.lowercased()).inserted { parts.append(label) }
        let mails = card.emailAddresses.count
        if mails == 1 { parts.append("Email") } else if mails > 1 { parts.append("\(mails) email addresses") }
        return (parts.prefix(3).joined(separator: " · "), false)
    }
}

/// Folds two cards for the same person into one (issue 205, section 2: merge). Nothing either holds is
/// lost: names come from the one kept, every number, address, label and note from both, each once.
public enum ContactMerge {
    public static func merge(keep: ContactCard, other: ContactCard, at now: Date) -> ContactCard {
        var card = keep
        func fill(_ path: WritableKeyPath<ContactCard, String>) {
            if card[keyPath: path].trimmingCharacters(in: .whitespaces).isEmpty { card[keyPath: path] = other[keyPath: path] }
        }
        fill(\.givenName)
        fill(\.familyName)
        fill(\.nickname)
        fill(\.company)
        card.photo = keep.photo ?? other.photo
        card.birthday = keep.birthday ?? other.birthday
        card.username = keep.username ?? other.username
        card.origin = keep.origin ?? other.origin
        card.isFavourite = keep.isFavourite || other.isFavourite
        card.favouriteOrder = keep.isFavourite ? keep.favouriteOrder : other.favouriteOrder
        let phones = Set(keep.phones.map { ContactSearch.digits($0.value) })
        card.phones += other.phones.filter { !phones.contains(ContactSearch.digits($0.value)) }
        let emails = Set(keep.emails.map { $0.value.lowercased() })
        card.emails += other.emails.filter { !emails.contains($0.value.lowercased()) }
        let places = Set(keep.addresses.map { $0.oneLine.lowercased() })
        card.addresses += other.addresses.filter { !places.contains($0.oneLine.lowercased()) }
        card.labels += other.labels
        let mine = keep.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let theirs = other.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if mine.isEmpty { card.notes = theirs } else if !theirs.isEmpty, mine != theirs { card.notes = "\(mine)\n\n\(theirs)" }
        card.createdAt = min(keep.createdAt, other.createdAt)
        card.updatedAt = now
        card.deletedAt = nil
        return card.tidied()
    }
}
