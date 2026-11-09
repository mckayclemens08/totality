import Foundation
import TotalityCore

/// Why Google Calendar couldn't be read, in words the Calendar can show.
public enum GoogleCalendarProblem: Error, Equatable, Sendable {
    /// No connection to the internet.
    case offline
    /// Google couldn't be reached properly, or is busy.
    case unreachable
    /// Google took Totality's access back, or it ran out. Connecting again fixes it.
    case expired
    /// The account is connected, but not for Calendar yet. One tap on Google's page allows it.
    case notAllowed
    /// Totality's own Google project isn't set up for Calendar, like the Calendar API not being turned on.
    /// Nothing the person can fix, and not their account's doing.
    case notSetUp
    /// Google said something that doesn't fit.
    case unexpected

    static func from(_ error: any Error) -> GoogleCalendarProblem {
        if let problem = error as? GoogleCalendarProblem { return problem }
        if let error = error as? GoogleSignInError {
            switch error {
            case .expired: return .expired
            case .notAllowed, .cancelled: return .notAllowed
            case .unreachable: return .unreachable
            case .refused, .unexpected: return .unexpected
            }
        }
        if let url = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(url.code) {
            return .offline
        }
        return .unreachable
    }

    public var message: String {
        switch self {
        case .offline: "You're offline. Google Calendar will update when you're back online."
        case .unreachable: "Google Calendar couldn't be reached. Pull down to try again."
        case .expired: "Google took back Totality's access to this account. Connect it again to keep seeing its calendars."
        case .notAllowed: "This Google account isn't allowed to share its calendars with Totality yet."
        case .notSetUp: "Totality isn't set up to read Google Calendar yet. That's on Totality's side, not your account's. Try again later."
        case .unexpected: "Google Calendar sent something Totality didn't understand. Pull down to try again."
        }
    }
}

/// One of the Google account's calendars, as its calendar list gives it.
public struct GoogleCalendarInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// Calendars someone else made, like holidays, that the person subscribed to.
    public let isSubscribed: Bool
    public let isPrimary: Bool
}

/// One event, as Google gives it, once it's been checked. A cancelled one only says which went.
public struct GoogleCalendarEvent: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let location: String
    public let notes: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// Google's own page for the event, only ever on calendar.google.com or google.com.
    public let link: URL?
}

/// One page of a calendar's events, and where to go next.
struct GoogleEventsPage: Sendable {
    var changed: [GoogleCalendarEvent] = []
    var cancelled: [String] = []
    var nextPage: String?
    var nextSync: String?
}

/// Google Calendar's API, read only. Every address is fixed in code, and calendar IDs go in the path
/// only once they're escaped, so an ID can't reach anywhere else.
struct GoogleCalendarAPI: Sendable {
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    static let base = URL(string: "https://www.googleapis.com/calendar/v3")!
    /// The most Google returns on one page.
    static let pageSize = 2_500

    let signIn: GoogleSignIn

    /// Every calendar the account can read: its own, ones shared with it, and ones it subscribed to.
    func calendars(accessToken: String) async throws -> [GoogleCalendarInfo] {
        var found: [GoogleCalendarInfo] = []
        var page: String?
        repeat {
            var components = URLComponents(url: Self.base.appendingPathComponent("users/me/calendarList"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "maxResults", value: "250"), URLQueryItem(name: "minAccessRole", value: "reader")]
                + (page.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            struct Entry: Decodable {
                let id: String
                let summary: String?
                let summaryOverride: String?
                let accessRole: String?
                let primary: Bool?
                let deleted: Bool?
            }
            struct Listing: Decodable {
                let items: [Entry]?
                let nextPageToken: String?
            }
            let listing: Listing = try await get(components.url!, accessToken: accessToken)
            for entry in listing.items ?? [] where entry.deleted != true && Self.isCalendarID(entry.id) {
                let title = Self.cleaned(entry.summaryOverride ?? entry.summary ?? "", limit: 200)
                found.append(GoogleCalendarInfo(
                    id: entry.id, title: title.isEmpty ? "Untitled calendar" : title,
                    isSubscribed: entry.accessRole == "reader" || entry.accessRole == "freeBusyReader",
                    isPrimary: entry.primary == true
                ))
            }
            page = listing.nextPageToken
        } while page != nil && found.count < 500
        return found
    }

    /// One page of a calendar's events. With a sync token, only what changed since it was given. Without
    /// one, everything from `from` to `to`, each repeat as its own event.
    func events(
        calendar: String, syncToken: String?, page: String?, from: Date, to: Date, accessToken: String
    ) async throws -> GoogleEventsPage {
        guard Self.isCalendarID(calendar) else { throw GoogleCalendarProblem.unexpected }
        let path = "calendars/\(calendar.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed)!)/events"
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = Self.base.path + "/" + path
        var items = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: "\(Self.pageSize)"),
            URLQueryItem(name: "showDeleted", value: syncToken == nil ? "false" : "true"),
        ]
        if let syncToken {
            items.append(URLQueryItem(name: "syncToken", value: syncToken))
        } else {
            items.append(URLQueryItem(name: "timeMin", value: Self.stamp(from)))
            items.append(URLQueryItem(name: "timeMax", value: Self.stamp(to)))
        }
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        struct Item: Decodable {
            let id: String
            let status: String?
            let summary: String?
            let description: String?
            let location: String?
            let start: GoogleWhen?
            let end: GoogleWhen?
            let htmlLink: String?
        }
        struct Listing: Decodable {
            let items: [Item]?
            let nextPageToken: String?
            let nextSyncToken: String?
        }
        let listing: Listing = try await get(components.url!, accessToken: accessToken)
        var result = GoogleEventsPage(nextPage: listing.nextPageToken, nextSync: listing.nextSyncToken)
        for item in listing.items ?? [] where Self.isEventID(item.id) {
            if item.status == "cancelled" {
                result.cancelled.append(item.id)
                continue
            }
            guard let start = item.start, let end = item.end, let times = Self.times(start: start, end: end) else { continue }
            result.changed.append(GoogleCalendarEvent(
                id: item.id,
                title: Self.cleaned(item.summary ?? "", limit: 500),
                location: Self.cleaned(item.location ?? "", limit: 500),
                notes: Self.notes(item.description ?? ""),
                start: times.start, end: times.end, isAllDay: times.isAllDay,
                link: item.htmlLink.flatMap(Self.googleLink)
            ))
        }
        return result
    }

    // MARK: Asking Google

    private func get<Answer: Decodable>(_ url: URL, accessToken: String) async throws -> Answer {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await signIn.send(request)
        } catch {
            throw GoogleCalendarProblem.from(error)
        }
        switch response.statusCode {
        case 200:
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw GoogleCalendarProblem.unexpected }
            return answer
        case 401: throw GoogleCalendarProblem.expired
        case 403:
            // Google says "too many" with a 403 as well as a 429. Either way, try again later.
            throw Self.refusal(data)
        case 410: throw GoogleSyncExpired()
        case 429, 500...: throw GoogleCalendarProblem.unreachable
        default: throw GoogleCalendarProblem.unexpected
        }
    }

    // MARK: Checking what Google says

    /// What a 403 means. Google says "too many" with a 403 as well as a 429, and a project without the
    /// Calendar API turned on is Totality's setup, not the person's permission.
    static func refusal(_ data: Data) -> GoogleCalendarProblem {
        let text = String(decoding: data.prefix(4_000), as: UTF8.self)
        if text.contains("ateLimitExceeded") || text.contains("RATE_LIMIT_EXCEEDED") { return .unreachable }
        if text.contains("accessNotConfigured") || text.contains("SERVICE_DISABLED") { return .notSetUp }
        return .notAllowed
    }

    static let pathAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// Calendar IDs look like addresses, or a long name ending in `@group.calendar.google.com`.
    static func isCalendarID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 1_024 && id.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    /// Event IDs are base32hex, with `_` and a date for a repeat's own instance.
    static func isEventID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 1_024 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// An all-day event is midnight GMT on its first and last days, like the person's own (contracts,
    /// Calendar). Google's end date is the day after the last, so a day is taken off.
    static func times(start: GoogleWhen, end: GoogleWhen) -> (start: Date, end: Date, isAllDay: Bool)? {
        if let first = start.date, let after = end.date {
            guard let from = day(first), let to = day(after) else { return nil }
            let last = max(from, to.addingTimeInterval(-86_400))
            return (from, last, true)
        }
        guard let from = start.dateTime.flatMap(moment), let to = end.dateTime.flatMap(moment) else { return nil }
        return (from, max(from, to), false)
    }

    private static func day(_ text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func moment(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "GMT")!))
    }

    /// Printable, one line, and not too long.
    static func cleaned(_ text: String, limit: Int) -> String {
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
        return String(printable.trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    /// Google's notes can hold simple HTML. They're shown as plain text, so tags are dropped and line
    /// breaks kept. Nothing in them is ever followed or loaded.
    static func notes(_ text: String) -> String {
        var plain = text
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</li>", "</div>"] {
            plain = plain.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        plain = plain.replacingOccurrences(of: "<[^>]{0,500}>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            plain = plain.replacingOccurrences(of: entity, with: character)
        }
        let kept = plain.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000))
    }

    /// Only Google's own pages, over HTTPS.
    static func googleLink(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              host == "www.google.com" || host == "calendar.google.com" else { return nil }
        return url
    }
}

/// Google's sync token was too old. Starting again from the beginning fixes it.
struct GoogleSyncExpired: Error {}

/// A start or an end, as Google writes it: a date for all day, or a moment.
struct GoogleWhen: Decodable, Sendable {
    var date: String?
    var dateTime: String?
}
