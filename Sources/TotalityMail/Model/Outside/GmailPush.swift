import Foundation
import TotalityCore

/// Instant Gmail sync (issue 164, CLAUDE.md rule 8). The phone asks Gmail to watch each inbox
/// (`users.watch`), Google tells Totality's server through Pub/Sub when it changes, and the server wakes
/// the phone with an empty push. The phone then fetches the new mail from Gmail itself and shows the
/// notification, which it builds here, so the server never sees a sender or subject.
///
/// Both settings belong to this device. iCloud has no push for outside apps, so it keeps its schedule.
/// `UserDefaults` is safe to use from any thread.
public struct GmailPushSettings: @unchecked Sendable {
    public static let shared = GmailPushSettings(defaults: .standard)

    private let defaults: UserDefaults
    private static let onKey = "mail.gmailPush.on"
    private static let detailsKey = "mail.gmailPush.details"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Instant sync, on unless turned off.
    public var isOn: Bool {
        get { defaults.object(forKey: Self.onKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.onKey) }
    }

    /// The notification shows the sender and subject, or only "New mail". Sender and subject unless
    /// changed: the phone writes it, so nobody else sees it.
    public var showsDetails: Bool {
        get { defaults.object(forKey: Self.detailsKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.detailsKey) }
    }
}

/// When each Gmail account's watch runs out, and whether its address is linked for push. Only account
/// IDs and dates, never an address.
public struct GmailWatchBook: @unchecked Sendable {
    public static let shared = GmailWatchBook(defaults: .standard)
    /// Gmail stops watching after 7 days. Renewing once less than this is left keeps it from lapsing,
    /// whether the phone opens the app daily or only wakes for mail.
    public static let renewWithin: TimeInterval = 2 * 86_400

    private let defaults: UserDefaults
    private static let prefix = "mail.gmailPush.watch."
    private static let allowPrefix = "mail.gmailPush.allow."

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func expiry(_ account: UUID) -> Date? {
        (defaults.object(forKey: Self.prefix + account.uuidString) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    public func set(_ account: UUID, expiry: Date?) {
        if let expiry { defaults.set(expiry.timeIntervalSince1970, forKey: Self.prefix + account.uuidString) }
        else { defaults.removeObject(forKey: Self.prefix + account.uuidString) }
    }

    public func needsRenewal(_ account: UUID, now: Date) -> Bool {
        guard let expiry = expiry(account) else { return true }
        return expiry.timeIntervalSince(now) < Self.renewWithin
    }

    /// A Gmail account added before instant sync, whose sign-in gives no ID token yet. One tap on
    /// Google's page allows it.
    public func needsAllow(_ account: UUID) -> Bool {
        defaults.bool(forKey: Self.allowPrefix + account.uuidString)
    }

    public func setNeedsAllow(_ account: UUID, _ needs: Bool) {
        if needs { defaults.set(true, forKey: Self.allowPrefix + account.uuidString) }
        else { defaults.removeObject(forKey: Self.allowPrefix + account.uuidString) }
    }

    /// Accounts with a watch recorded, for turning them all off.
    public func watched() -> [UUID] {
        defaults.dictionaryRepresentation().keys.compactMap { key in
            key.hasPrefix(Self.prefix) ? UUID(uuidString: String(key.dropFirst(Self.prefix.count))) : nil
        }
    }
}

/// What the app hands Mail so it can keep the watches going: the Pub/Sub topic Gmail posts to, and the
/// way to reach Totality's push service.
public struct GmailPushPlan: Sendable {
    public let topic: String
    public let push: PushClient
    public let settings: GmailPushSettings
    public let book: GmailWatchBook

    /// Nil when this build has no topic, so instant sync is off until the owner sets one up.
    public init?(topic: String?, push: PushClient, settings: GmailPushSettings = .shared, book: GmailWatchBook = .shared) {
        guard let topic = topic?.trimmingCharacters(in: .whitespaces), Self.isTopic(topic) else { return nil }
        self.topic = topic
        self.push = push
        self.settings = settings
        self.book = book
    }

    /// `projects/<project>/topics/<topic>`, as Google names them.
    static func isTopic(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "projects", parts[2] == "topics" else { return false }
        return parts[1].count >= 4 && parts[3].count >= 3 && name.count <= 255
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./~%+".contains($0)) }
    }
}

extension GoogleOAuth {
    static let watchURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/watch")!
    static let stopURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/stop")!

    /// Asks Gmail to tell `topic` whenever the Inbox changes. Returns when that watch runs out.
    func watch(topic: String, accessToken: String) async throws -> Date {
        var request = URLRequest(url: Self.watchURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "topicName": topic, "labelIds": ["INBOX"], "labelFilterBehavior": "INCLUDE",
        ])
        let (data, response) = try await sendRequest(request)
        switch response.statusCode {
        case 200: break
        case 401: throw OutsideMailProblem.expired
        case 403: throw OutsideMailProblem.notAllowed
        default: throw OutsideMailProblem.unreachable
        }
        struct Answer: Decodable { let expiration: String }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), let milliseconds = Double(answer.expiration) else {
            throw OutsideMailProblem.unexpected
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Stops Gmail telling the topic anything about this account. Best effort.
    func stopWatching(accessToken: String) async {
        var request = URLRequest(url: Self.stopURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await sendRequest(request)
    }
}

/// One new-mail notification, written on the phone.
public struct NewMailNote: Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// Says it's an email, and from which kind of account, so it can't be mistaken for anything else.
    public let subtitle: String
    public let body: String
    public let conversationID: UUID
    /// The account it came to, so one account's alerts group together.
    public let account: UUID

    public init(id: UUID, title: String, subtitle: String, body: String, conversationID: UUID, account: UUID) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.conversationID = conversationID
        self.account = account
    }

    /// "New email · Gmail".
    public static func subtitle(for provider: OutsideProvider) -> String {
        "New email \u{00B7} \(provider.name)"
    }

    /// Unread Gmail mail that the Inbox lists in `after` but wasn't in `before`, newest first. Includes
    /// all Inbox mail (Primary, Promotions, Social, Updates). With `details` off, each just says
    /// "New email" and which account.
    public static func notes(before: Mailbox, after: Mailbox, details: Bool, most: Int = 5) -> [NewMailNote] {
        let known = Set(before.messages.map(\.id))
        let fresh = after.messages
            .filter { !known.contains($0.id) && $0.outsideAccount?.provider == .gmail && $0.marks.isUnread && MailPlace.inbox.lists($0) }
            .sorted { $0.date > $1.date }
        return fresh.prefix(most).compactMap { message in
            guard let account = message.outsideAccount else { return nil }
            let subtitle = subtitle(for: account.provider)
            if details {
                let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                return NewMailNote(
                    id: message.id, title: message.from.displayName, subtitle: subtitle,
                    body: subject.isEmpty ? "No subject" : subject, conversationID: message.conversationID, account: account.id
                )
            }
            return NewMailNote(
                id: message.id, title: "New email", subtitle: subtitle, body: account.address,
                conversationID: message.conversationID, account: account.id
            )
        }
    }
}
