import Foundation

/// One message downloaded from an outside account, exactly as the provider gave it. It's sealed on this
/// device and never leaves it.
public struct OutsideFetchedMessage: Codable, Equatable, Sendable {
    /// The outside account it came from.
    public let outside: UUID
    /// The provider's own name for it: Gmail's message ID, or IMAP's UIDVALIDITY and UID.
    public let providerID: String
    public let received: Date
    public let raw: Data
    /// Unread at the provider when it was downloaded. Marks made in Totality take over from here.
    public let isUnread: Bool
    /// Starred (Gmail) or flagged (iCloud) at the provider when it was downloaded.
    public let isStarred: Bool
    /// Its Gmail labels when it was downloaded, for when the places record says nothing newer.
    public let labels: [String]

    public init(
        outside: UUID, providerID: String, received: Date, raw: Data, isUnread: Bool, isStarred: Bool = false, labels: [String] = []
    ) {
        self.outside = outside
        self.providerID = providerID
        self.received = received
        self.raw = raw
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.labels = labels
    }

    private enum CodingKeys: String, CodingKey { case outside, providerID, received, raw, isUnread, isStarred, labels }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outside = try container.decode(UUID.self, forKey: .outside)
        providerID = try container.decode(String.self, forKey: .providerID)
        received = try container.decode(Date.self, forKey: .received)
        raw = try container.decode(Data.self, forKey: .raw)
        isUnread = try container.decode(Bool.self, forKey: .isUnread)
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

/// An outside account's own places, and which messages are in each, by the provider's names for both.
/// Gmail only: its tabs, and the labels the person made.
public struct OutsideAccountPlaces: Codable, Equatable, Sendable {
    public let outside: UUID
    public let labels: [OutsideLabel]
    /// Each listed message's places. INBOX is among them while it's in the Inbox.
    public let membership: [String: [String]]
    /// Every place was listed in full since `since`, so a message from then that isn't listed is in none.
    public let complete: Bool
    public let since: Date

    /// Its places at the provider, or nil when this says nothing about it.
    func labels(of providerID: String, received: Date) -> Set<String>? {
        if let found = membership[providerID] { return Set(found) }
        return complete && received >= since ? [] : nil
    }
}

/// How much is downloaded: the newest 90 days of the Inbox (issue 43, decision 5), and no more than
/// this many messages from one account in one go, so a huge Inbox fills in over a few opens.
public enum OutsideReading {
    public static let days = 90
    public static let mostPerOpen = 500
    /// How many IDs are listed from one place, to know what's where. Listing is cheap; downloading isn't.
    public static let mostListed = 2_000

    static func since(_ now: Date) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }

    /// Who added the checks at the top of mail from each provider, so the sender can be proved.
    static func checkedBy(_ provider: OutsideProvider) -> [String] {
        switch provider {
        case .gmail: ["mx.google.com"]
        case .icloud: [".icloud.com"]
        }
    }
}

// MARK: - Gmail

extension GoogleOAuth {
    static let messagesURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!

    static let labelsURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels")!
    /// More labels than this and the rest aren't shown.
    static let mostLabels = 100

    /// The labels the person made, by name. Gmail's own (Sent, Important and the rest) are left out.
    func userLabels(accessToken: String) async throws -> [OutsideLabel] {
        struct Listing: Decodable {
            struct Label: Decodable { let id: String; let name: String; let type: String? }
            let labels: [Label]?
        }
        let listing: Listing = try await gmail(Self.labelsURL, accessToken: accessToken)
        return (listing.labels ?? [])
            .filter { $0.type == "user" && Self.isLabelID($0.id) && !$0.name.isEmpty }
            .map { OutsideLabel(id: $0.id, name: String($0.name.prefix(200))) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(Self.mostLabels).map { $0 }
    }

    /// The message IDs in one label since `since`, newest first, up to `limit`. Truncated when there were more.
    func ids(in label: String, accessToken: String, since: Date, limit: Int) async throws -> (ids: [String], truncated: Bool) {
        guard Self.isLabelID(label) else { throw OutsideMailProblem.unexpected }
        var ids: [String] = []
        var page: String?
        repeat {
            var components = URLComponents(url: Self.messagesURL, resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "labelIds", value: label),
                URLQueryItem(name: "q", value: "after:\(Int(since.timeIntervalSince1970))"),
                URLQueryItem(name: "maxResults", value: String(min(500, limit - ids.count))),
            ]
            if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
            components.queryItems = items
            struct Listing: Decodable {
                struct Entry: Decodable { let id: String }
                let messages: [Entry]?
                let nextPageToken: String?
            }
            let listing: Listing = try await gmail(components.url!, accessToken: accessToken)
            ids += (listing.messages ?? []).map(\.id).filter(Self.isGmailID)
            page = listing.nextPageToken
        } while page != nil && ids.count < limit
        return (Array(ids.prefix(limit)), page != nil)
    }

    /// Gmail's label IDs are its own words (INBOX, CATEGORY_SOCIAL) or `Label_` and a number.
    static func isLabelID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// One message as Gmail keeps it, with whether it's unread there.
    func message(_ id: String, accessToken: String) async throws -> (raw: Data, received: Date, isUnread: Bool, isStarred: Bool, labels: [String]) {
        guard Self.isGmailID(id) else { throw OutsideMailProblem.unexpected }
        var components = URLComponents(url: Self.messagesURL.appendingPathComponent(id), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "raw")]
        struct Message: Decodable {
            let raw: String
            let internalDate: String?
            let labelIds: [String]?
        }
        let message: Message = try await gmail(components.url!, accessToken: accessToken)
        var base64 = message.raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let raw = Data(base64Encoded: base64) else { throw OutsideMailProblem.unexpected }
        let received = message.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let labels = (message.labelIds ?? []).filter(Self.isLabelID)
        return (raw, received, labels.contains("UNREAD"), labels.contains("STARRED"), labels)
    }

    /// Gmail's IDs are hex. Anything else never goes into a path.
    static func isGmailID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    func gmail<Answer: Decodable>(_ url: URL, accessToken: String, posting body: [String: [String]]? = nil) async throws -> Answer {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await sendRequest(request)
        switch response.statusCode {
        case 200: break
        case 401: throw OutsideMailProblem.expired
        case 403: throw OutsideMailProblem.notAllowed
        case 404: throw OutsideMailProblem.unexpected
        default: throw OutsideMailProblem.unreachable
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw OutsideMailProblem.unexpected }
        return answer
    }
}

// MARK: - IMAP

extension IMAPConnection {
    struct Fetched: Equatable {
        let uid: UInt32
        let raw: Data
        let received: Date?
        let isUnread: Bool
        let isStarred: Bool
    }

    /// Opens the Inbox read-only, so nothing there changes by being looked at. Returns its UIDVALIDITY,
    /// which names this run of UIDs.
    func examineInbox() async throws -> UInt32 {
        let tag = takeTag()
        try await reader.send("\(tag) EXAMINE INBOX")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        for line in untagged {
            let text = String(decoding: line, as: UTF8.self)
            if let range = text.range(of: "[UIDVALIDITY ", options: .caseInsensitive) {
                let digits = text[range.upperBound...].prefix { $0.isNumber }
                if let value = UInt32(digits) { return value }
            }
        }
        throw OutsideMailProblem.unexpected
    }

    /// The Inbox's UIDs since a day, newest first.
    func uids(since: Date) async throws -> [UInt32] {
        let tag = takeTag()
        try await reader.send("\(tag) UID SEARCH SINCE \(Self.imapDay(since))")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        var found: [UInt32] = []
        for line in untagged {
            let text = String(decoding: line, as: UTF8.self)
            guard text.uppercased().hasPrefix("* SEARCH") else { continue }
            found += text.dropFirst(8).split(separator: " ").compactMap { UInt32($0) }
        }
        return found.sorted(by: >)
    }

    /// Whole messages by UID, without marking them read.
    func fetch(_ uids: [UInt32]) async throws -> [Fetched] {
        guard !uids.isEmpty else { return [] }
        let tag = takeTag()
        try await reader.send("\(tag) UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID FLAGS INTERNALDATE BODY.PEEK[])")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        return untagged.compactMap(Self.fetched)
    }

    /// One `* n FETCH (...)` answer, with its body as the literal `readUntilTagged` read in.
    static func fetched(_ line: Data) -> Fetched? {
        let bytes = [UInt8](line)
        guard let marker = find(Array("BODY[] {".utf8), in: bytes) else { return nil }
        let open = marker + 7
        guard let close = bytes[open...].firstIndex(of: UInt8(ascii: "}")),
              let count = Int(String(decoding: bytes[(open + 1)..<close], as: UTF8.self)),
              close + 3 + count <= bytes.count, bytes[close + 1] == 13, bytes[close + 2] == 10 else { return nil }
        let raw = Data(bytes[(close + 3)..<(close + 3 + count)])
        // Everything but the body, where the other items are, in whatever order the server sent them.
        let rest = String(decoding: bytes[..<marker], as: UTF8.self) + " " + String(decoding: bytes[(close + 3 + count)...], as: UTF8.self)
        guard rest.hasPrefix("* "), rest.uppercased().contains(" FETCH ("),
              let uid = number(after: "UID ", in: rest).flatMap(UInt32.init) else { return nil }
        let flags = value(in: rest, after: "FLAGS (", until: ")") ?? ""
        let date = value(in: rest, after: "INTERNALDATE \"", until: "\"").flatMap(internalDate)
        return Fetched(
            uid: uid, raw: raw, received: date, isUnread: !flags.lowercased().contains("\\seen"), isStarred: flags.lowercased().contains("\\flagged")
        )
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
        return nil
    }

    private static func number(after word: String, in text: String) -> String? {
        guard let range = text.range(of: word, options: .caseInsensitive) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static func value(in text: String, after start: String, until end: Character) -> String? {
        guard let range = text.range(of: start, options: .caseInsensitive) else { return nil }
        return String(text[range.upperBound...].prefix { $0 != end })
    }

    static func imapDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }

    static func internalDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}

/// Downloads an outside account's newest Inbox mail that this device doesn't have yet.
struct OutsideReader: Sendable {
    let maker: any OutsideWireMaker
    let google: GoogleOAuth?

    /// `have` says whether a provider ID is already here, or was deleted here. Each message is handed to
    /// `keep` as it arrives, so what came before a dropped connection isn't lost.
    func download(
        _ account: OutsideAccount, credential: OutsideCredential, since: Date,
        have: @Sendable (String) async throws -> Bool, keep: @Sendable (OutsideFetchedMessage) async throws -> Void,
        places: @Sendable (OutsideAccountPlaces) async throws -> Void = { _ in }
    ) async throws {
        switch credential {
        case .google(let grant):
            guard let google else { throw OutsideAccountError.notSetUp }
            let token = try await google.accessToken(for: grant)
            // Which messages are in the Inbox, each tab and each label, so they show in the same places here.
            let labels = OutsideLabel.tabs + (try await google.userLabels(accessToken: token))
            var membership: [String: [String]] = [:]
            var order: [String] = []
            var complete = true
            for label in ["INBOX"] + labels.map(\.id) {
                try Task.checkCancellation()
                let listed = try await google.ids(in: label, accessToken: token, since: since, limit: OutsideReading.mostListed)
                complete = complete && !listed.truncated
                for id in listed.ids {
                    if membership[id] == nil { order.append(id) }
                    membership[id, default: []].append(label)
                }
            }
            try await places(OutsideAccountPlaces(outside: account.id, labels: labels, membership: membership, complete: complete, since: since))
            var downloaded = 0
            for id in order where downloaded < OutsideReading.mostPerOpen {
                try Task.checkCancellation()
                guard try await !have(id) else { continue }
                downloaded += 1
                let message = try await google.message(id, accessToken: token)
                try await keep(OutsideFetchedMessage(
                    outside: account.id, providerID: id, received: message.received, raw: message.raw, isUnread: message.isUnread,
                    isStarred: message.isStarred, labels: message.labels
                ))
            }
        case .appPassword(let password):
            guard let signIn = OutsideSignIn(provider: account.provider, address: account.address, appPassword: password) else {
                throw OutsideAccountError.notFound
            }
            let connection = try await IMAPConnection.signIn(signIn, with: maker)
            do {
                let validity = try await connection.examineInbox()
                var missing: [UInt32] = []
                for uid in try await connection.uids(since: since).prefix(OutsideReading.mostPerOpen) where try await !have("\(validity).\(uid)") {
                    missing.append(uid)
                }
                // A few at a time, so one huge message doesn't hold up the rest.
                for start in stride(from: 0, to: missing.count, by: 10) {
                    try Task.checkCancellation()
                    for fetched in try await connection.fetch(Array(missing[start..<min(start + 10, missing.count)])) {
                        try await keep(OutsideFetchedMessage(
                            outside: account.id, providerID: "\(validity).\(fetched.uid)", received: fetched.received ?? Date(),
                            raw: fetched.raw, isUnread: fetched.isUnread, isStarred: fetched.isStarred
                        ))
                    }
                }
                await connection.signOut()
            } catch {
                await connection.signOut()
                throw error
            }
        }
    }
}
