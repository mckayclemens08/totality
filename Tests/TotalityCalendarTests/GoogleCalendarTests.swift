import Foundation
import Testing
import TotalityCore
@testable import TotalityCalendar

private let clientID = "204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0.apps.googleusercontent.com"
private let me = "mckay.clemens@gmail.com"

/// Stands in for Google: the token endpoint, the calendar list, and events with sync tokens.
private final class FakeGoogleCalendar: GoogleHTTP, @unchecked Sendable {
    private let lock = NSLock()
    var calendars: [[String: Any]] = [
        ["id": me, "summary": me, "summaryOverride": "Personal", "accessRole": "owner", "primary": true],
        ["id": "en.usa#holiday@group.v.calendar.google.com", "summary": "Holidays in United States", "accessRole": "reader"],
    ]
    /// Each calendar's full event list, and what changed since each sync token Google gave.
    var events: [String: [[String: Any]]] = [:]
    var changes: [String: [[String: Any]]] = [:]
    var syncTokenGone = false
    var status = 200
    private(set) var asked: [URLComponents] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url == GoogleSignIn.tokenURL { return answer(200, ["access_token": "ya29.calendar"]) }
        if url == GoogleSignIn.revokeURL { return answer(200, [:]) }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.calendar")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        lock.withLock { asked.append(components) }
        if status != 200 { return answer(status, ["error": ["message": "no"]]) }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        if components.path == "/calendar/v3/users/me/calendarList" { return answer(200, ["items": calendars]) }
        let prefix = "/calendar/v3/calendars/", suffix = "/events"
        #expect(components.path.hasPrefix(prefix) && components.path.hasSuffix(suffix))
        let calendar = String(components.path.dropFirst(prefix.count).dropLast(suffix.count))
        #expect(query["singleEvents"] == "true")
        if let token = query["syncToken"] {
            #expect(query["timeMin"] == nil && query["timeMax"] == nil)
            if syncTokenGone { return answer(410, ["error": ["message": "Sync token is no longer valid"]]) }
            #expect(token == "sync-1")
            return answer(200, ["items": changes[calendar] ?? [], "nextSyncToken": "sync-2"])
        }
        #expect(query["timeMin"] != nil && query["timeMax"] != nil)
        let all = events[calendar] ?? []
        // Two pages, to check paging.
        if query["pageToken"] == nil, all.count > 1 {
            return answer(200, ["items": Array(all.prefix(1)), "nextPageToken": "page-2"])
        }
        return answer(200, ["items": query["pageToken"] == nil ? all : Array(all.dropFirst()), "nextSyncToken": "sync-1"])
    }

    var eventRequests: [URLComponents] { lock.withLock { asked }.filter { $0.path.hasSuffix("/events") } }

    private func answer(_ status: Int, _ body: [String: Any]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: GoogleSignIn.tokenURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

nonisolated(unsafe) private let dentist: [String: Any] = [
    "id": "4kq2v8dentist", "status": "confirmed", "summary": "Dentist, Dr. Okafor", "location": "418 Elm Street",
    "description": "Bring the insurance card.<br>Floss beforehand &amp; <b>relax</b>.",
    "start": ["dateTime": "2026-11-10T09:30:00-07:00"], "end": ["dateTime": "2026-11-10T10:15:00-07:00"],
    "htmlLink": "https://www.google.com/calendar/event?eid=NGtxMnY4ZGVudGlzdA",
]
nonisolated(unsafe) private let trip: [String: Any] = [
    "id": "7rr0tripmoab", "summary": "Moab trip", "start": ["date": "2026-11-20"], "end": ["date": "2026-11-23"],
    "htmlLink": "https://evil.example/phish",
]

private func setUp(_ fake: FakeGoogleCalendar, keys: MemoryKeys = MemoryKeys(), store: MemoryBlobs = MemoryBlobs(), rootKey: ContentRootKey? = nil, grant: Bool = true) throws -> (GoogleCalendars, GoogleAccounts) {
    let accounts = GoogleAccounts(signIn: try #require(GoogleSignIn(clientID: clientID, http: fake)), keychain: keys)
    if grant {
        try accounts.keep(address: me, refreshToken: "1//shared", granted: [GoogleCalendarAPI.scope, "https://www.googleapis.com/auth/gmail.modify"])
    }
    let calendars = GoogleCalendars(accounts: accounts, store: store, rootKey: try rootKey ?? .generate(), now: { Dates.date(2026, 11, 8, 12) })
    return (calendars, accounts)
}

@Suite struct GoogleCalendarTests {
    @Test func readsCalendarsAndTheirEvents() async throws {
        let fake = FakeGoogleCalendar()
        fake.events[me] = [dentist, trip]
        let (calendars, _) = try setUp(fake)
        let result = await calendars.sync()
        #expect(result.problems.isEmpty)
        let account = try #require(result.accounts.first)
        #expect(account.calendars.map(\.info.title) == ["Personal", "Holidays in United States"])
        // Holidays are someone else's, so they start off and aren't read.
        #expect(account.calendars.map(\.isOn) == [true, false])
        #expect(fake.eventRequests.allSatisfy { $0.percentEncodedPath.contains("mckay.clemens%40gmail.com") })

        let shown = await calendars.events(from: Dates.date(2026, 11, 1), to: Dates.date(2026, 12, 1))
        #expect(shown.count == 2)
        let visit = try #require(shown.first { $0.title == "Dentist, Dr. Okafor" })
        #expect(visit.location == "418 Elm Street")
        #expect(visit.notes == "Bring the insurance card.\nFloss beforehand & relax.")
        #expect(visit.end.timeIntervalSince(visit.start) == 45 * 60)
        #expect(visit.calendarTitle == "Personal")
        #expect(visit.origin == .google(account: me, link: URL(string: "https://www.google.com/calendar/event?eid=NGtxMnY4ZGVudGlzdA")))
        // All day: midnight GMT on the first and last days. Google's end is the day after.
        let away = try #require(shown.first { $0.title == "Moab trip" })
        #expect(away.isAllDay)
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = TimeZone(identifier: "GMT")!
        #expect(gmt.dateComponents([.month, .day], from: away.start) == DateComponents(month: 11, day: 20))
        #expect(gmt.dateComponents([.month, .day], from: away.end) == DateComponents(month: 11, day: 22))
        // A link anywhere but Google's own pages is dropped.
        #expect(away.origin == .google(account: me, link: nil))
    }

    @Test func onlyChangesComeBackAfterTheFirstTime() async throws {
        let fake = FakeGoogleCalendar()
        fake.events[me] = [dentist, trip]
        let (calendars, _) = try setUp(fake)
        _ = await calendars.sync()
        var moved = dentist
        moved["summary"] = "Dentist, moved to Thursday"
        fake.changes[me] = [moved, ["id": "7rr0tripmoab", "status": "cancelled"]]
        let before = fake.eventRequests.count
        let result = await calendars.sync()
        #expect(result.problems.isEmpty)
        #expect(fake.eventRequests.count == before + 1)
        let shown = await calendars.events(from: Dates.date(2026, 11, 1), to: Dates.date(2026, 12, 1))
        #expect(shown.map(\.title) == ["Dentist, moved to Thursday"])
    }

    @Test func startsAgainWhenGoogleSaysTheSyncTokenIsTooOld() async throws {
        let fake = FakeGoogleCalendar()
        fake.events[me] = [dentist]
        let (calendars, _) = try setUp(fake)
        _ = await calendars.sync()
        fake.syncTokenGone = true
        fake.events[me] = [trip]
        let result = await calendars.sync()
        #expect(result.problems.isEmpty)
        let shown = await calendars.events(from: Dates.date(2026, 11, 1), to: Dates.date(2026, 12, 1))
        #expect(shown.map(\.title) == ["Moab trip"])
    }

    @Test func keepsWhatItHadWhenGoogleCantBeReached() async throws {
        let fake = FakeGoogleCalendar()
        fake.events[me] = [dentist]
        let (calendars, _) = try setUp(fake)
        _ = await calendars.sync()
        fake.status = 503
        let result = await calendars.sync()
        #expect(result.problems[me] == .unreachable)
        #expect(result.accounts.first?.calendars.first?.events.count == 1)
        fake.status = 401
        #expect(await calendars.sync().problems[me] == .expired)
    }

    @Test func aCalendarThatsOffKeepsNothing() async throws {
        let fake = FakeGoogleCalendar()
        fake.events[me] = [dentist]
        let (calendars, _) = try setUp(fake)
        _ = await calendars.sync()
        try await calendars.setOn(false, calendar: me, account: me)
        #expect(await calendars.kept().first?.calendars.first?.events.isEmpty == true)
        #expect(await calendars.events(from: Dates.date(2026, 11, 1), to: Dates.date(2026, 12, 1)).isEmpty)
        let before = fake.eventRequests.count
        _ = await calendars.sync()
        #expect(fake.eventRequests.count == before)
    }

    @Test func anAccountWithoutCalendarIsAskedToAllowIt() async throws {
        let fake = FakeGoogleCalendar()
        let keys = MemoryKeys()
        let (calendars, accounts) = try setUp(fake, keys: keys, grant: false)
        try accounts.keep(address: me, refreshToken: "1//mail", granted: ["https://www.googleapis.com/auth/gmail.modify"])
        let result = await calendars.sync()
        #expect(result.needsAllowing == [me])
        #expect(fake.eventRequests.isEmpty)
        // One tap on Google's page, for that account, keeping what it already gave.
        let page = try #require(await calendars.authorization(for: me))
        let query = Dictionary((URLComponents(url: page.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        #expect(query["login_hint"] == me && query["include_granted_scopes"] == "true")
        #expect(query["scope"] == "\(GoogleCalendarAPI.scope) openid email")
        #expect(await calendars.alsoEnds(me) == [.mail])
    }

    @Test func disconnectingForgetsItsCalendars() async throws {
        let fake = FakeGoogleCalendar()
        fake.events[me] = [dentist]
        let store = MemoryBlobs()
        let (calendars, accounts) = try setUp(fake, store: store)
        _ = await calendars.sync()
        #expect(try store.names() == [GoogleCalendars.name(me)])
        await calendars.disconnect(me)
        #expect(try store.names().isEmpty)
        #expect(try accounts.connections().isEmpty)
    }

    @Test func anAccountDisconnectedElsewhereLeavesNothing() async throws {
        let fake = FakeGoogleCalendar()
        fake.events[me] = [dentist]
        let store = MemoryBlobs()
        let (calendars, accounts) = try setUp(fake, store: store)
        _ = await calendars.sync()
        try accounts.forget(me)
        _ = await calendars.sync()
        #expect(try store.names().isEmpty)
    }

    /// The owner saw "isn't allowed" when the Calendar API was off in Totality's own project (2026-11-09).
    @Test func tellsSetupApartFromPermission() {
        let disabled = #"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}],"status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#
        let refused = #"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED"}}"#
        let busy = #"{"error":{"code":403,"errors":[{"reason":"rateLimitExceeded"}]}}"#
        #expect(GoogleCalendarAPI.refusal(Data(disabled.utf8)) == .notSetUp)
        #expect(GoogleCalendarAPI.refusal(Data(refused.utf8)) == .notAllowed)
        #expect(GoogleCalendarAPI.refusal(Data(busy.utf8)) == .unreachable)
        #expect(!GoogleCalendarProblem.notSetUp.message.contains("account isn't"))
    }

    @Test func refusesWhatDoesntFit() {
        #expect(!GoogleCalendarAPI.isCalendarID(""))
        #expect(!GoogleCalendarAPI.isCalendarID("a b"))
        #expect(GoogleCalendarAPI.isCalendarID("en.usa#holiday@group.v.calendar.google.com"))
        #expect(!GoogleCalendarAPI.isEventID("../../x"))
        #expect(GoogleCalendarAPI.isEventID("7rr0tripmoab_20261120"))
        #expect(GoogleCalendarAPI.googleLink("http://www.google.com/calendar") == nil)
        #expect(GoogleCalendarAPI.googleLink("https://calendar.google.com.evil.example/") == nil)
        #expect(GoogleCalendarAPI.googleLink("https://calendar.google.com/calendar/r") != nil)
        #expect(GoogleCalendarAPI.notes("<script>alert(1)</script>Lunch") == "alert(1)Lunch")
    }
}

@Suite struct GoogleCalendarTwoUserTests {
    @Test("User 2 cannot read user 1's Google calendars kept on a device")
    func user2CannotRead() async throws {
        let fake = FakeGoogleCalendar()
        fake.events[me] = [dentist]
        let store = MemoryBlobs()
        let (mine, _) = try setUp(fake, store: store)
        _ = await mine.sync()
        // Nothing readable at rest: no title, place, notes, address or calendar name.
        for text in ["Dentist", "Okafor", "Elm Street", "insurance", "mckay", "Personal"] {
            #expect(store.everything.range(of: Data(text.utf8)) == nil)
        }
        #expect(!(try store.names().joined().contains("mckay")))

        // User 2 on the same storage, with their own key and no Google connection of user 1's.
        let (theirs, _) = try setUp(fake, store: store, grant: false)
        #expect(await theirs.kept().isEmpty)
        #expect(await theirs.events(from: Dates.date(2026, 11, 1), to: Dates.date(2026, 12, 1)).isEmpty)

        // Even with user 1's Google connection, user 2's key opens nothing user 1 kept.
        let (wrongKey, _) = try setUp(fake, store: store, grant: true)
        #expect(await wrongKey.kept().isEmpty)
    }
}
