import CryptoKit
import Foundation
import TotalityCore

/// What Totality may see of the iPhone's own Contacts.
public enum DeviceAccess: Equatable, Sendable {
    case notAsked
    /// Only the contacts the person picked (iOS 18 and later).
    case limited
    case full
    case denied
}

/// One contact as the iPhone's Contacts app holds it: only the fields Totality copies. Notes are never
/// read, because that needs an entitlement Totality doesn't have (issue 205, section 4).
public struct DeviceContact: Identifiable, Hashable, Sendable {
    public let id: String
    public var givenName: String
    public var familyName: String
    public var nickname: String
    public var company: String
    public var phones: [ContactCard.Field]
    public var emails: [ContactCard.Field]
    public var addresses: [ContactCard.Address]
    public var birthday: ContactCard.Birthday?
    /// The thumbnail as it came. It's rebuilt by `SafeAvatar` before it goes on a card.
    public var photo: Data?

    public init(
        id: String, givenName: String = "", familyName: String = "", nickname: String = "", company: String = "",
        phones: [ContactCard.Field] = [], emails: [ContactCard.Field] = [], addresses: [ContactCard.Address] = [],
        birthday: ContactCard.Birthday? = nil, photo: Data? = nil
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.company = company
        self.phones = phones
        self.emails = emails
        self.addresses = addresses
        self.birthday = birthday
        self.photo = photo
    }

    /// A hash of the fields Totality copies, ignoring the random IDs of each row, so a change made in iPhone
    /// Contacts shows and nothing else does.
    public var fingerprint: String {
        var parts = [givenName, familyName, nickname, company]
        parts += phones.map { "p\($0.label)=\($0.value)" } + emails.map { "e\($0.label)=\($0.value)" }
        parts += addresses.map { "a\($0.label)=\($0.street)|\($0.city)|\($0.region)|\($0.postcode)|\($0.country)" }
        parts.append(birthday.map { "b\($0.month)-\($0.day)-\($0.year ?? 0)" } ?? "b")
        parts.append(photo.map { Data(SHA256.hash(data: $0)).base64EncodedString() } ?? "")
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var name: String {
        let full = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? (company.isEmpty ? (emails.first?.value ?? phones.first?.value ?? "No name") : company) : full
    }

    /// A new card copied from this contact, sealed by the caller.
    func card(at now: Date) -> ContactCard {
        var card = ContactCard(createdAt: now)
        apply(to: &card, at: now)
        return card
    }

    /// Copies the iPhone's fields onto a card, keeping everything that's Totality's own: notes, labels,
    /// favourite and the @username link.
    func apply(to card: inout ContactCard, at now: Date) {
        card.givenName = givenName
        card.familyName = familyName
        card.nickname = nickname
        card.company = company
        card.phones = phones
        card.emails = emails
        card.addresses = addresses
        card.birthday = birthday
        if let photo { card.photo = SafeAvatar.prepare(photo) } else { card.photo = nil }
        card.origin = ContactCard.Origin(deviceID: id, copiedAt: now, fingerprint: fingerprint)
        card.updatedAt = now
    }

    /// The contact as the card now has it, for writing back with two-way sync. Same ID, so it updates.
    static func from(_ card: ContactCard, id: String) -> DeviceContact {
        DeviceContact(
            id: id, givenName: card.givenName, familyName: card.familyName, nickname: card.nickname, company: card.company,
            phones: card.phones, emails: card.emails, addresses: card.addresses, birthday: card.birthday
        )
    }
}

/// The iPhone's Contacts, behind a protocol so tests can stand in for it.
public protocol DeviceContacts: Sendable {
    var access: DeviceAccess { get }
    /// Asks once. On iOS 18 the person can share only some contacts.
    func requestAccess() async -> DeviceAccess
    /// Every contact Totality may see.
    func all() async throws -> [DeviceContact]
    /// These contacts, by ID. Any that are gone or no longer shared are left out.
    func contacts(_ ids: [String]) async throws -> [DeviceContact]
    /// Writes the card's fields over the contact with the same ID. Photo and notes aren't touched.
    func update(_ contact: DeviceContact) async throws
}

/// What changed in iPhone Contacts since a card was copied, shown before anything is saved.
public struct ContactUpdate: Identifiable, Hashable, Sendable {
    public let card: ContactCard
    public let contact: DeviceContact
    /// Such as "Mobile (801) 555-0110 → (801) 555-0187", or "+ priya.patel@byu.edu".
    public let changes: [String]

    public var id: UUID { card.id }

    /// The change for each copied card whose iPhone contact is different now.
    public static func pending(_ cards: [ContactCard], device: [DeviceContact]) -> [ContactUpdate] {
        let byID = Dictionary(device.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return cards.compactMap { card in
            guard !card.isDeleted, let origin = card.origin, let contact = byID[origin.deviceID],
                  contact.fingerprint != origin.fingerprint
            else { return nil }
            let changes = describe(card, contact)
            return ContactUpdate(card: card, contact: contact, changes: changes.isEmpty ? ["Photo"] : changes)
        }
        .sorted { $0.card.sortKey < $1.card.sortKey }
    }

    static func describe(_ card: ContactCard, _ contact: DeviceContact) -> [String] {
        var lines: [String] = []
        func compare(_ label: String, _ old: String, _ new: String) {
            guard old != new else { return }
            if old.isEmpty { lines.append("\(label) + \(new)") } else if new.isEmpty { lines.append("\(label) − \(old)") } else { lines.append("\(label) \(old) → \(new)") }
        }
        compare("Name", [card.givenName, card.familyName].joined(separator: " ").trimmingCharacters(in: .whitespaces),
                [contact.givenName, contact.familyName].joined(separator: " ").trimmingCharacters(in: .whitespaces))
        compare("Nickname", card.nickname, contact.nickname)
        compare("Company", card.company, contact.company)
        func rows(_ old: [String], _ new: [String], _ label: String) {
            for added in new where !old.contains(added) { lines.append("\(label) + \(added)") }
            for removed in old where !new.contains(removed) { lines.append("\(label) − \(removed)") }
        }
        rows(card.phones.map(\.value), contact.phones.map(\.value), "Phone")
        rows(card.emails.map(\.value), contact.emails.map(\.value), "Email")
        rows(card.addresses.map(\.oneLine), contact.addresses.map(\.oneLine), "Address")
        if card.birthday != contact.birthday { lines.append("Birthday") }
        return lines
    }
}
