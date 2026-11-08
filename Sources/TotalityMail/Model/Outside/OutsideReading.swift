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

    public init(outside: UUID, providerID: String, received: Date, raw: Data, isUnread: Bool) {
        self.outside = outside
        self.providerID = providerID
        self.received = received
        self.raw = raw
        self.isUnread = isUnread
    }
}

/// How much is downloaded: the newest 90 days of the Inbox (issue 43, decision 5), and no more than
/// this many messages from one account in one go, so a huge Inbox fills in over a few opens.
public enum OutsideReading {
    public static let days = 90
    public static let mostPerOpen = 500

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

    /// The Inbox's message IDs since `since`, newest first, up to `limit`.
    func inboxIDs(accessToken: String, since: Date, limit: Int) async throws -> [String] {
        var ids: [String] = []
        var page: String?
        repeat {
            var components = URLComponents(url: Self.messagesURL, resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "q", value: "in:inbox after:\(Int(since.timeIntervalSince1970))"),
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
        return Array(ids.prefix(limit))
    }

    /// One message as Gmail keeps it, with whether it's unread there.
    func message(_ id: String, accessToken: String) async throws -> (raw: Data, received: Date, isUnread: Bool) {
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
        return (raw, received, message.labelIds?.contains("UNREAD") ?? false)
    }

    /// Gmail's IDs are hex. Anything else never goes into a path.
    static func isGmailID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    private func gmail<Answer: Decodable>(_ url: URL, accessToken: String) async throws -> Answer {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
        return Fetched(uid: uid, raw: raw, received: date, isUnread: !flags.lowercased().contains("\\seen"))
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
        have: @Sendable (String) async throws -> Bool, keep: @Sendable (OutsideFetchedMessage) async throws -> Void
    ) async throws {
        switch credential {
        case .google(let grant):
            guard let google else { throw OutsideAccountError.notSetUp }
            let token = try await google.accessToken(for: grant)
            for id in try await google.inboxIDs(accessToken: token, since: since, limit: OutsideReading.mostPerOpen) {
                try Task.checkCancellation()
                guard try await !have(id) else { continue }
                let message = try await google.message(id, accessToken: token)
                try await keep(OutsideFetchedMessage(
                    outside: account.id, providerID: id, received: message.received, raw: message.raw, isUnread: message.isUnread
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
                            raw: fetched.raw, isUnread: fetched.isUnread
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
