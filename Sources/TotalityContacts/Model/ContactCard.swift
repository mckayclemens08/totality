import Foundation
import TotalityCore

/// One card in Contacts: the person's own private card about someone (issue 205, section 2). Everything in
/// it is sealed on this device before it syncs, photo included. A link to an @username points at that
/// person's public profile and never changes it.
public struct ContactCard: Codable, Identifiable, Hashable, Sendable {
    /// A phone number or email address with its label, such as "Mobile" or "Home".
    public struct Field: Codable, Identifiable, Hashable, Sendable {
        public var id: UUID
        public var label: String
        public var value: String

        public init(id: UUID = UUID(), label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }

        public var isEmpty: Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public struct Address: Codable, Identifiable, Hashable, Sendable {
        public var id: UUID
        public var label: String
        public var street: String
        public var city: String
        public var region: String
        public var postcode: String
        public var country: String

        public init(
            id: UUID = UUID(), label: String = "Home", street: String = "", city: String = "", region: String = "",
            postcode: String = "", country: String = ""
        ) {
            self.id = id
            self.label = label
            self.street = street
            self.city = city
            self.region = region
            self.postcode = postcode
            self.country = country
        }

        /// The address on one line, such as "1060 N 900 E, Provo, UT 84604".
        public var oneLine: String {
            let place = [city, [region, postcode].filter { !$0.isEmpty }.joined(separator: " ")].filter { !$0.isEmpty }
            return ([street.replacingOccurrences(of: "\n", with: ", ")] + place + [country])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }

        public var isEmpty: Bool { oneLine.isEmpty }
    }

    /// A birthday: always a month and a day, and the year when it's known.
    public struct Birthday: Codable, Hashable, Sendable {
        public var month: Int
        public var day: Int
        public var year: Int?

        public init(month: Int, day: Int, year: Int? = nil) {
            self.month = month
            self.day = day
            self.year = year
        }

        public var isValid: Bool {
            (1...12).contains(month) && (1...Self.daysIn(month)).contains(day) && (year.map { (1...9999).contains($0) } ?? true)
        }

        static func daysIn(_ month: Int) -> Int {
            switch month {
            case 2: 29
            case 4, 6, 9, 11: 30
            default: 31
            }
        }
    }

    /// Where a card was copied from on this person's iPhones, so Update from iPhone and two-way sync can
    /// find it again. `fingerprint` is a hash of the fields as they were last copied, so a change made in
    /// iPhone Contacts shows. It stays inside the seal like everything else.
    public struct Origin: Codable, Hashable, Sendable {
        public var deviceID: String
        public var copiedAt: Date
        public var fingerprint: String

        public init(deviceID: String, copiedAt: Date, fingerprint: String) {
            self.deviceID = deviceID
            self.copiedAt = copiedAt
            self.fingerprint = fingerprint
        }
    }

    public let id: UUID
    public var givenName: String
    public var familyName: String
    public var nickname: String
    public var company: String
    /// A small square JPEG rebuilt on this device by `SafeAvatar`, never a file as it came.
    public var photo: Data?
    public var phones: [Field]
    public var emails: [Field]
    public var addresses: [Address]
    public var birthday: Birthday?
    /// Totality's own notes. iPhone Contacts' notes are never read (section 4).
    public var notes: String
    /// Such as "Family" or "Climbing". A label is also a group that can be mailed at once.
    public var labels: [String]
    public var isFavourite: Bool
    /// Where it sits among the favourites, lowest first.
    public var favouriteOrder: Double
    /// The Totality handle it's linked to, lowercased and without the @, set by hand.
    public var username: String?
    public var origin: Origin?
    public var createdAt: Date
    public var updatedAt: Date
    /// When it went to Recently Deleted. It's kept, sealed and syncing, for 30 days.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), givenName: String = "", familyName: String = "", nickname: String = "", company: String = "",
        photo: Data? = nil, phones: [Field] = [], emails: [Field] = [], addresses: [Address] = [], birthday: Birthday? = nil,
        notes: String = "", labels: [String] = [], isFavourite: Bool = false, favouriteOrder: Double = 0,
        username: String? = nil, origin: Origin? = nil, createdAt: Date = Date(), updatedAt: Date? = nil, deletedAt: Date? = nil
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.company = company
        self.photo = photo
        self.phones = phones
        self.emails = emails
        self.addresses = addresses
        self.birthday = birthday
        self.notes = notes
        self.labels = labels
        self.isFavourite = isFavourite
        self.favouriteOrder = favouriteOrder
        self.username = username
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    // A card written by a newer version may carry fields this one doesn't know, and an older card may lack
    // ones added since. Every field but the ID has a default, so neither stops a card from opening.
    private enum CodingKeys: String, CodingKey {
        case id, givenName, familyName, nickname, company, photo, phones, emails, addresses, birthday, notes, labels
        case isFavourite, favouriteOrder, username, origin, createdAt, updatedAt, deletedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        givenName = try c.decodeIfPresent(String.self, forKey: .givenName) ?? ""
        familyName = try c.decodeIfPresent(String.self, forKey: .familyName) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? ""
        photo = try c.decodeIfPresent(Data.self, forKey: .photo)
        phones = try c.decodeIfPresent([Field].self, forKey: .phones) ?? []
        emails = try c.decodeIfPresent([Field].self, forKey: .emails) ?? []
        addresses = try c.decodeIfPresent([Address].self, forKey: .addresses) ?? []
        birthday = try c.decodeIfPresent(Birthday.self, forKey: .birthday)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        isFavourite = try c.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        favouriteOrder = try c.decodeIfPresent(Double.self, forKey: .favouriteOrder) ?? 0
        username = try c.decodeIfPresent(String.self, forKey: .username)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    // MARK: What it's called

    /// "Given Family", or the nickname, company, an address or a number when there's no name.
    public var name: String {
        let full = [givenName, familyName].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        for fallback in [nickname, company] + emails.map(\.value) + phones.map(\.value) {
            let trimmed = fallback.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return "No name"
    }

    /// What the list and favourites show: the nickname if there is one, else the name.
    public var shownName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// The first word of what it's called, for the favourites and tiles, such as "Sam".
    public var shortName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let given = givenName.trimmingCharacters(in: .whitespaces)
        return given.isEmpty ? name : given
    }

    /// The list is in order of family name, then given name, as in iPhone Contacts.
    public var sortKey: String {
        let family = familyName.trimmingCharacters(in: .whitespaces)
        let key = family.isEmpty ? shownName : "\(family) \(givenName)"
        return key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// The @handle shown, such as "@samokafor".
    public var handle: String? { username.map { "@\($0)" } }

    /// Every email address on the card, without blanks or repeats.
    public var emailAddresses: [String] {
        var seen = Set<String>()
        return emails.map { $0.value.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public var phoneNumbers: [String] {
        phones.map { $0.value.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Drops blank rows and repeated labels, and lowercases the handle, before a save.
    public func tidied() -> ContactCard {
        var card = self
        card.phones.removeAll(where: \.isEmpty)
        card.emails.removeAll(where: \.isEmpty)
        card.addresses.removeAll(where: \.isEmpty)
        var seen = Set<String>()
        card.labels = labels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        card.username = username.flatMap(ContactCard.normalizedHandle)
        if let birthday, !birthday.isValid { card.birthday = nil }
        return card
    }

    /// A handle as typed, such as "@SamOkafor", in the form Totality uses, or nil if it can't be one.
    public static func normalizedHandle(_ typed: String) -> String? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("@") { name.removeFirst() }
        return name.wholeMatch(of: /[a-z0-9_]{3,24}/) != nil ? name : nil
    }

    /// The Totality Mail address of a linked card, which always reaches them.
    public var totalityAddress: String? {
        username.map { "\($0)@\(MailDomain.name)" }
    }

    /// The person as other modules see them through `PeopleLookup`.
    public var known: KnownPerson {
        var addresses = emailAddresses
        if let totalityAddress, !addresses.contains(where: { $0.lowercased() == totalityAddress }) { addresses.append(totalityAddress) }
        let nick = nickname.trimmingCharacters(in: .whitespaces)
        return KnownPerson(id: id, name: name, nickname: nick.isEmpty ? nil : nick, emails: addresses, username: username, photo: photo)
    }
}
