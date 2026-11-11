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
    /// The event changed in Google Calendar after it was opened here, so the change wasn't sent over it.
    case changedOnGoogle
    /// Already deleted at Google. Only used inside, where it means there's nothing left to do.
    case gone

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
        case .changedOnGoogle: "This event changed in Google Calendar. Check it and save again."
        case .gone: "This event is no longer in Google Calendar."
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
    /// The person's own calendar, the only kind Totality changes (issue 88, decision 3).
    public let isOwned: Bool

    public init(id: String, title: String, isSubscribed: Bool, isPrimary: Bool, isOwned: Bool) {
        self.id = id
        self.title = title
        self.isSubscribed = isSubscribed
        self.isPrimary = isPrimary
        self.isOwned = isOwned
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        isSubscribed = try values.decode(Bool.self, forKey: .isSubscribed)
        isPrimary = try values.decode(Bool.self, forKey: .isPrimary)
        // Kept from before editing existed. The next sync says.
        isOwned = try values.decodeIfPresent(Bool.self, forKey: .isOwned) ?? false
    }
}

/// One event, as Google gives it, once it's been checked. A cancelled one only says which went.
public struct GoogleCalendarEvent: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let location: String
    public let notes: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// Google's own page for the event, only ever on calendar.google.com or google.com.
    public let link: URL?
    /// Google's version of the event, sent back with a change so a newer one is never overwritten.
    public var etag: String?
    /// The repeating event this is one of, or nil.
    public var seriesID: String?
    /// The event has guests. Totality never changes them or emails them.
    public var hasGuests: Bool

    public init(
        id: String, title: String, location: String, notes: String, start: Date, end: Date, isAllDay: Bool, link: URL?,
        etag: String? = nil, seriesID: String? = nil, hasGuests: Bool = false
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.link = link
        self.etag = etag
        self.seriesID = seriesID
        self.hasGuests = hasGuests
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        location = try values.decode(String.self, forKey: .location)
        notes = try values.decode(String.self, forKey: .notes)
        start = try values.decode(Date.self, forKey: .start)
        end = try values.decode(Date.self, forKey: .end)
        isAllDay = try values.decode(Bool.self, forKey: .isAllDay)
        link = try values.decodeIfPresent(URL.self, forKey: .link)
        etag = try values.decodeIfPresent(String.self, forKey: .etag)
        seriesID = try values.decodeIfPresent(String.self, forKey: .seriesID)
        hasGuests = try values.decodeIfPresent(Bool.self, forKey: .hasGuests) ?? false
    }
}

/// What a create or an edit sends to Google: only these fields, and never guests (issue 88, decision 4).
public struct GoogleEventBody: Equatable, Sendable {
    public var title: String
    public var location: String
    public var notes: String
    public var start: Date
    /// For all day, the last day, which Google wants as the day after.
    public var end: Date
    public var isAllDay: Bool
    /// Only for a new event. An edit leaves how it repeats to Google Calendar.
    public var repeatRule: RepeatRule?
    public var timeZone: TimeZone

    public init(title: String, location: String, notes: String, start: Date, end: Date, isAllDay: Bool, repeatRule: RepeatRule? = nil, timeZone: TimeZone = .current) {
        self.title = title
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.repeatRule = repeatRule
        self.timeZone = timeZone
    }

    /// Google's JSON for a new event, or, given what was opened, only what changed. Notes Google
    /// keeps with formatting are shown here as plain text, so untouched notes are never sent back.
    func json(changedFrom original: GoogleCalendarEvent? = nil) -> [String: Any] {
        guard let original else { return full(includingRepeat: true) }
        let all = full(includingRepeat: false)
        var body: [String: Any] = [:]
        if title != original.title { body["summary"] = all["summary"] }
        if location != original.location { body["location"] = all["location"] }
        if notes != original.notes { body["description"] = all["description"] }
        if start != original.start || end != original.end || isAllDay != original.isAllDay {
            body["start"] = all["start"]
            body["end"] = all["end"]
        }
        return body
    }

    /// All-day days are midnight GMT here, like everywhere in the Calendar. Google wants a timed
    /// event's zone too, which it needs for repeats.
    private func full(includingRepeat: Bool) -> [String: Any] {
        var body: [String: Any] = ["summary": title, "location": location, "description": notes]
        if isAllDay {
            body["start"] = ["date": Self.day(start)]
            body["end"] = ["date": Self.day(end.addingTimeInterval(86_400))]
        } else {
            body["start"] = ["dateTime": GoogleCalendarAPI.stamp(start), "timeZone": timeZone.identifier]
            body["end"] = ["dateTime": GoogleCalendarAPI.stamp(end), "timeZone": timeZone.identifier]
        }
        if includingRepeat, let rule = repeatRule { body["recurrence"] = [rruleLine(rule)] }
        return body
    }

    func rruleLine(_ rule: RepeatRule) -> String {
        var line = "RRULE:FREQ=\(rule.frequency.rawValue.uppercased())"
        if let until = rule.until {
            if isAllDay {
                line += ";UNTIL=" + String(format: "%04d%02d%02d", until.year, until.month, until.day)
            } else {
                // The end of that day where the event is, in UTC, as RFC 5545 asks.
                var zoned = Calendar(identifier: .gregorian)
                zoned.timeZone = timeZone
                let last = until.adding(days: 1, in: zoned).start(in: zoned).addingTimeInterval(-1)
                var gmt = Calendar(identifier: .gregorian)
                gmt.timeZone = TimeZone(identifier: "GMT")!
                let p = gmt.dateComponents([.year, .month, .day, .hour, .minute, .second], from: last)
                line += ";UNTIL=" + String(format: "%04d%02d%02dT%02d%02d%02dZ", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
            }
        }
        return line
    }

    static func day(_ date: Date) -> String {
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = TimeZone(identifier: "GMT")!
        let p = gmt.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
}

/// A repeating event's own start and end, for moving every occurrence.
struct GoogleSeries: Sendable {
    var etag: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var timeZone: TimeZone?
}

/// One page of a calendar's events, and where to go next.
struct GoogleEventsPage: Sendable {
    var changed: [GoogleCalendarEvent] = []
    var cancelled: [String] = []
    var nextPage: String?
    var nextSync: String?
}

/// Google Calendar's API: reading, and changing events on the person's own calendars. Every address is fixed in code, and calendar IDs go in the path
/// only once they're escaped, so an ID can't reach anywhere else.
struct GoogleCalendarAPI: Sendable {
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    /// Creating, changing and deleting events, only on calendars the person owns (issue 88, decision 1).
    static let editScope = "https://www.googleapis.com/auth/calendar.events.owned"
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
                    isPrimary: entry.primary == true,
                    isOwned: entry.accessRole == "owner"
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
            let etag: String?
            let recurringEventId: String?
            let attendees: [Guest]?
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
                link: item.htmlLink.flatMap(Self.googleLink),
                etag: item.etag.flatMap(Self.etag),
                seriesID: item.recurringEventId.flatMap { Self.isEventID($0) ? $0 : nil },
                hasGuests: !(item.attendees ?? []).isEmpty
            ))
        }
        return result
    }

    // MARK: Changing events (issue 88)

    /// Adds an event. Google emails nobody, because Totality never adds guests and says so.
    func insert(_ body: GoogleEventBody, calendar: String, accessToken: String) async throws {
        let url = try Self.eventsURL(calendar: calendar, event: nil)
        _ = try await change("POST", url, body: body.json(), etag: nil, accessToken: accessToken)
    }

    /// Changes one event, or a whole repeating one by its series ID. Only if it's still the version
    /// that was opened: otherwise Google says 412 and nothing changes.
    func patch(_ body: GoogleEventBody, from original: GoogleCalendarEvent, calendar: String, event: String, etag: String?, accessToken: String) async throws {
        let changes = body.json(changedFrom: original)
        guard !changes.isEmpty else { return }
        let url = try Self.eventsURL(calendar: calendar, event: event)
        _ = try await change("PATCH", url, body: changes, etag: etag, accessToken: accessToken)
    }

    /// Moves an event to Google Calendar's bin. One that's already gone is fine.
    func delete(calendar: String, event: String, etag: String?, accessToken: String) async throws {
        let url = try Self.eventsURL(calendar: calendar, event: event)
        do {
            _ = try await change("DELETE", url, body: nil, etag: etag, accessToken: accessToken)
        } catch GoogleCalendarProblem.gone {
            return
        }
    }

    /// A repeating event's own times and version, to move all of it.
    func series(calendar: String, event: String, accessToken: String) async throws -> GoogleSeries {
        struct Item: Decodable {
            let etag: String?
            let start: GoogleWhen?
            let end: GoogleWhen?
        }
        let item: Item = try await get(try Self.eventsURL(calendar: calendar, event: event), accessToken: accessToken)
        guard let start = item.start, let end = item.end, let times = Self.times(start: start, end: end) else {
            throw GoogleCalendarProblem.unexpected
        }
        return GoogleSeries(
            etag: item.etag.flatMap(Self.etag), start: times.start, end: times.end, isAllDay: times.isAllDay,
            timeZone: (start.timeZone).flatMap(TimeZone.init(identifier:))
        )
    }

    static func eventsURL(calendar: String, event: String?) throws -> URL {
        guard isCalendarID(calendar), event.map(isEventID) ?? true else { throw GoogleCalendarProblem.unexpected }
        var path = Self.base.path + "/calendars/\(calendar.addingPercentEncoding(withAllowedCharacters: pathAllowed)!)/events"
        if let event { path += "/" + event }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: "none")]
        return components.url!
    }

    private func change(_ method: String, _ url: URL, body: [String: Any]?, etag: String?, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await signIn.send(request)
        } catch {
            throw GoogleCalendarProblem.from(error)
        }
        switch response.statusCode {
        case 200...204: return data
        case 401: throw GoogleCalendarProblem.expired
        case 403: throw Self.refusal(data)
        case 404, 410: throw method == "DELETE" ? GoogleCalendarProblem.gone : GoogleCalendarProblem.changedOnGoogle
        case 412: throw GoogleCalendarProblem.changedOnGoogle
        case 429, 500...: throw GoogleCalendarProblem.unreachable
        default: throw GoogleCalendarProblem.unexpected
        }
    }

    /// Google's ETags are short quoted strings. Anything else isn't sent back.
    static func etag(_ text: String) -> String? {
        guard text.count <= 200, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return nil }
        return text
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
    var timeZone: String?
}

struct Guest: Decodable, Sendable {}
