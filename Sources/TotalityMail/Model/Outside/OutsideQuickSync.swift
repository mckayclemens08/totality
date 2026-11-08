import Foundation

/// Bringing outside accounts up to date without starting over. Gmail is asked what changed since its
/// last history point; iCloud folders that haven't changed aren't read again, and in one that has, only
/// new mail's headers are fetched. Everything already downloaded stays sealed on the device.
enum OutsideQuickSync {
    /// Past this, every Gmail label is listed again in full, so nothing history missed lasts.
    static let relist: TimeInterval = 7 * 86_400
    /// More pages of history than this and a full listing is quicker.
    static let mostHistoryPages = 10
}

/// What changed in Gmail since a history point.
struct GmailHistory: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        /// Labels are nil when Gmail didn't say them.
        case added(String, labels: [String]?)
        case deleted(String)
        case labelled(String, added: [String], now: [String]?)
        case unlabelled(String, removed: [String], now: [String]?)
    }

    /// Where history stands now.
    let id: String
    /// Oldest first.
    let changes: [Change]
}

extension GoogleOAuth {
    /// Where the mailbox's history stands now.
    func historyID(accessToken: String) async throws -> String {
        struct Profile: Decodable { let historyId: String? }
        let profile: Profile = try await gmail(Self.profileURL, accessToken: accessToken)
        guard let id = profile.historyId, Self.isHistoryID(id) else { throw OutsideMailProblem.unexpected }
        return id
    }

    static let historyURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/history")!

    static func isHistoryID(_ id: String) -> Bool { (1...20).contains(id.count) && id.allSatisfy(\.isASCII) && id.allSatisfy(\.isNumber) }

    /// Everything that changed since `start`, or nil when Gmail no longer keeps history that far back
    /// or there's too much of it, and a full listing is needed.
    func history(since start: String, accessToken: String) async throws -> GmailHistory? {
        guard Self.isHistoryID(start) else { return nil }
        struct Page: Decodable {
            struct Entry: Decodable { let message: Message; let labelIds: [String]? }
            struct Message: Decodable { let id: String; let labelIds: [String]? }
            struct Record: Decodable {
                let messagesAdded: [Entry]?
                let messagesDeleted: [Entry]?
                let labelsAdded: [Entry]?
                let labelsRemoved: [Entry]?
            }
            let history: [Record]?
            let nextPageToken: String?
            let historyId: String?
        }
        func labels(_ ids: [String]?) -> [String]? { ids?.filter(Self.isLabelID) }
        var changes: [GmailHistory.Change] = []
        var page: String?, latest = start
        for _ in 0..<OutsideQuickSync.mostHistoryPages {
            var components = URLComponents(url: Self.historyURL, resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "startHistoryId", value: start), URLQueryItem(name: "maxResults", value: "500")]
            items += ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"].map { URLQueryItem(name: "historyTypes", value: $0) }
            if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
            components.queryItems = items
            let answer: Page
            do {
                answer = try await gmail(components.url!, accessToken: accessToken)
            } catch GmailMissing.message {
                // History that old is gone: start over with a full listing.
                return nil
            }
            for record in answer.history ?? [] {
                for entry in record.messagesAdded ?? [] where Self.isGmailID(entry.message.id) {
                    changes.append(.added(entry.message.id, labels: labels(entry.message.labelIds)))
                }
                for entry in record.labelsAdded ?? [] where Self.isGmailID(entry.message.id) {
                    changes.append(.labelled(entry.message.id, added: labels(entry.labelIds) ?? [], now: labels(entry.message.labelIds)))
                }
                for entry in record.labelsRemoved ?? [] where Self.isGmailID(entry.message.id) {
                    changes.append(.unlabelled(entry.message.id, removed: labels(entry.labelIds) ?? [], now: labels(entry.message.labelIds)))
                }
                for entry in record.messagesDeleted ?? [] where Self.isGmailID(entry.message.id) {
                    changes.append(.deleted(entry.message.id))
                }
            }
            if let id = answer.historyId, Self.isHistoryID(id) { latest = id }
            page = answer.nextPageToken
            if page == nil { return GmailHistory(id: latest, changes: changes) }
        }
        return nil
    }

    /// One message's labels, without its content.
    func labelIDs(of id: String, accessToken: String) async throws -> [String] {
        guard Self.isGmailID(id) else { throw OutsideMailProblem.unexpected }
        var components = URLComponents(url: Self.messagesURL.appendingPathComponent(id), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "minimal")]
        struct Message: Decodable { let labelIds: [String]? }
        let message: Message = try await gmail(components.url!, accessToken: accessToken)
        return (message.labelIds ?? []).filter(Self.isLabelID)
    }
}

extension OutsideAccountPlaces {
    /// Whether a message is downloaded for being where it is: in the Inbox, a tab or a label of the
    /// person's, and not in Spam or Trash.
    func downloads(_ id: String) -> Bool {
        guard let labels = membership[id], !labels.contains("SPAM"), !labels.contains("TRASH") else { return false }
        return labels.contains("INBOX") || labels.contains { label in self.labels.contains { $0.id == label } }
    }
}

extension OutsideReader {
    /// Gmail brought up to date from its last history point, or nil when it has to be listed in full.
    func quickGmail(
        _ previous: OutsideAccountPlaces, labels: [OutsideLabel], google: GoogleOAuth, token: String, now: Date
    ) async throws -> (OutsideAccountPlaces, [String])? {
        guard let start = previous.historyID, let listed = previous.listedAt,
              now.timeIntervalSince(listed) < OutsideQuickSync.relist, now >= listed,
              let history = try await google.history(since: start, accessToken: token) else { return nil }
        var places = previous
        places.historyID = history.id
        places.labels = labels
        // A label made since the last full listing: what's in it from before isn't known.
        for label in labels where !previous.labels.contains(where: { $0.id == label.id }) { places.truncated.insert(label.id) }
        var changed: [String] = []
        for change in history.changes {
            try Task.checkCancellation()
            switch change {
            case .added(let id, let labels):
                if let labels {
                    places.membership[id] = labels
                } else if let labels = try? await google.labelIDs(of: id, accessToken: token) {
                    places.membership[id] = labels
                }
                changed.append(id)
            case .labelled(let id, let added, let now):
                if let now { places.membership[id] = now } else if let had = places.membership[id] {
                    places.membership[id] = Array(Set(had).union(added)).sorted()
                }
                changed.append(id)
            case .unlabelled(let id, let removed, let now):
                if let now { places.membership[id] = now } else if let had = places.membership[id] {
                    places.membership[id] = had.filter { !removed.contains($0) }
                }
                changed.append(id)
            case .deleted(let id):
                places.membership[id] = nil
            }
        }
        // Newest first, then whatever the last open didn't get to.
        var order: [String] = [], seen = Set<String>()
        for id in changed.reversed() + (previous.waiting ?? []) where !seen.contains(id) {
            seen.insert(id)
            if places.downloads(id) { order.append(id) }
        }
        return (places, order)
    }

    /// Every label listed from `since`, as on the first open. History's point is taken first, so nothing
    /// that changes while it lists is missed next time.
    func fullGmail(
        _ account: OutsideAccount, labels: [OutsideLabel], google: GoogleOAuth, token: String, since: Date, now: Date
    ) async throws -> (OutsideAccountPlaces, [String]) {
        let start = try? await google.historyID(accessToken: token)
        var membership: [String: [String]] = [:]
        var order: [String] = [], ordered = Set<String>()
        var truncated = Set<String>()
        for label in OutsideAccountPlaces.marking + labels.map(\.id) {
            try Task.checkCancellation()
            let listed: (ids: [String], truncated: Bool)
            do {
                listed = try await google.ids(in: label, accessToken: token, since: since, limit: OutsideReading.mostListed)
            } catch let problem as OutsideMailProblem where label != "INBOX" && problem != .expired && problem != .offline {
                // One label that won't list doesn't stop the rest. What's in it is just less certain.
                truncated.insert(label)
                continue
            }
            if listed.truncated { truncated.insert(label) }
            // Mail is downloaded from the Inbox and the places shown, never only for being unread or in Spam.
            let downloads = !["UNREAD", "STARRED", "SPAM", "TRASH"].contains(label)
            for id in listed.ids {
                if downloads, ordered.insert(id).inserted { order.append(id) }
                membership[id, default: []].append(label)
            }
        }
        let places = OutsideAccountPlaces(
            outside: account.id, labels: labels, membership: membership, truncated: truncated, since: since,
            historyID: start, listedAt: start == nil ? nil : now
        )
        return (places, order)
    }
}

// MARK: - iCloud

/// A folder's state when opened: its UIDVALIDITY, the UID the next message will get, and with CONDSTORE
/// a number that changes whenever anything in it does.
struct OutsideIMAPStatus: Equatable, Sendable {
    let validity: UInt32
    let uidNext: UInt32?
    let modseq: UInt64?

    static func from(_ untagged: [Data]) -> OutsideIMAPStatus? {
        var validity: UInt32?, uidNext: UInt32?, modseq: UInt64?
        for line in untagged {
            let text = String(decoding: line, as: UTF8.self)
            func number(_ code: String) -> Substring? {
                guard let range = text.range(of: "[\(code) ", options: .caseInsensitive) else { return nil }
                let digits = text[range.upperBound...].prefix { $0.isNumber }
                return digits.isEmpty ? nil : digits
            }
            if let found = number("UIDVALIDITY").flatMap({ UInt32($0) }) { validity = found }
            if let found = number("UIDNEXT").flatMap({ UInt32($0) }) { uidNext = found }
            if let found = number("HIGHESTMODSEQ").flatMap({ UInt64($0) }) { modseq = found }
        }
        return validity.map { OutsideIMAPStatus(validity: $0, uidNext: uidNext, modseq: modseq) }
    }
}

extension IMAPConnection {
    /// Opens a folder read-only and says where it stands. The Inbox's name goes unquoted, as it always has.
    func status(of mailbox: String) async throws -> OutsideIMAPStatus {
        guard Self.isMailboxName(mailbox) else { throw OutsideMailProblem.unexpected }
        let tag = takeTag()
        try await reader.send("\(tag) EXAMINE \(mailbox == "INBOX" ? "INBOX" : Self.quoted(mailbox))")
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        guard let status = OutsideIMAPStatus.from(untagged) else { throw OutsideMailProblem.unexpected }
        return status
    }
}

extension OutsideReader {
    /// Opens one iCloud folder read-only and notes what's in it from `since`: flags and Message-IDs only.
    /// When nothing in it has changed since `previous`, nothing more is asked; otherwise only new mail's
    /// headers are fetched.
    func look(
        in name: String, kind: OutsideFolders.Kind, connection: IMAPConnection, since: Date, previous: OutsideIMAPFolder?
    ) async throws -> OutsideIMAPFolder {
        let status = try await connection.status(of: name)
        let known = previous.flatMap { $0.validity == status.validity && $0.name == name ? $0 : nil }
        if let known, let modseq = status.modseq, known.modseq == modseq, known.uidNext == status.uidNext, known.kind == kind {
            return known
        }
        let all = try await connection.uids(since: since)
        let listed = Array(all.prefix(OutsideReading.mostListed))
        var entries: [UInt32: OutsideIMAPEntry] = [:]
        let had = listed.filter { known?.entries[$0]?.messageID != nil }
        let new = listed.filter { known?.entries[$0]?.messageID == nil }
        for start in stride(from: 0, to: had.count, by: 500) {
            try Task.checkCancellation()
            let flags = try await connection.flags(Array(had[start..<min(start + 500, had.count)]))
            for (uid, flag) in flags {
                entries[uid] = OutsideIMAPEntry(messageID: known?.entries[uid]?.messageID, isUnread: flag.isUnread, isStarred: flag.isStarred)
            }
        }
        for start in stride(from: 0, to: new.count, by: 500) {
            try Task.checkCancellation()
            entries.merge(try await connection.entries(Array(new[start..<min(start + 500, new.count)]))) { first, _ in first }
        }
        return OutsideIMAPFolder(
            name: name, kind: kind, validity: status.validity, entries: entries, complete: listed.count == all.count,
            uidNext: status.uidNext, modseq: status.modseq
        )
    }
}
