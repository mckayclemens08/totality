import Foundation
import Testing
import TotalityCore
@testable import TotalityCalendar

private let clientID = "204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0.apps.googleusercontent.com"
private let me = "mckay.clemens@gmail.com"
private let holidays = "en.usa#holiday@group.v.calendar.google.com"
private let family = "family0k2p@group.calendar.google.com"

/// Stands in for Google: tokens, the calendar list, events, and changes, which it records. A change
/// before `allowWrites` is a failure, so a test can prove nothing is sent before the press.
private final class FakeGoogleWrites: GoogleHTTP, @unchecked Sendable {
    private let lock = NSLock()
    var calendars: [[String: Any]] = [
        ["id": me, "summary": me, "summaryOverride": "Personal", "accessRole": "owner", "primary": true],
        ["id": family, "summary": "Clemens family", "accessRole": "writer"],
        ["id": holidays, "summary": "Holidays in United States", "accessRole": "reader"],
    ]
    var events: [[String: Any]] = []
    var series: [String: Any] = [:]
    /// What Google answers a change with.
    var writeStatus = 200
    var offline = false
    var allowWrites = true
    private(set) var writes: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url == GoogleSignIn.tokenURL { return answer(200, ["access_token": "ya29.calendar"]) }
        if url == GoogleSignIn.revokeURL { return answer(200, [:]) }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.calendar")
        let method = request.httpMethod ?? "GET"
        if method != "GET" {
            #expect(allowWrites, "A change reached Google before the person pressed Save to Google")
            lock.withLock { writes.append(request) }
            if offline { throw URLError(.notConnectedToInternet) }
            return answer(writeStatus, writeStatus == 200 ? ["id": "newevent0001", "status": "confirmed"] : ["error": ["message": "no"]])
        }
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        if components.path == "/calendar/v3/users/me/calendarList" { return answer(200, ["items": calendars]) }
        if components.path.hasSuffix("/events") {
            let mine = components.percentEncodedPath.contains("mckay.clemens%40gmail.com")
            return answer(200, ["items": mine ? events : [], "nextSyncToken": "sync-1"])
        }
        return answer(200, series)
    }

    var changes: [URLRequest] { lock.withLock { writes } }

    private func answer(_ status: Int, _ body: [String: Any]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: GoogleSignIn.tokenURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

nonisolated(unsafe) private let dentist: [String: Any] = [
    "id": "4kq2v8dentist", "etag": "\"3381920000000000\"", "status": "confirmed", "summary": "Dentist, Dr. Okafor",
    "location": "418 Elm Street", "description": "Bring the insurance card.<br><b>Floss</b>.",
    "start": ["dateTime": "2026-11-10T09:30:00-07:00"], "end": ["dateTime": "2026-11-10T10:15:00-07:00"],
    "attendees": [["email": "front.desk@okaforsmiles.example"]],
]
nonisolated(unsafe) private let standup: [String: Any] = [
    "id": "9wkstandup_20261111T160000Z", "etag": "\"3381920000000111\"", "recurringEventId": "9wkstandup",
    "summary": "Team standup", "start": ["dateTime": "2026-11-11T09:00:00-07:00"], "end": ["dateTime": "2026-11-11T09:15:00-07:00"],
]

private func setUp(_ fake: FakeGoogleWrites, editing: Bool = true) async throws -> GoogleCalendars {
    let accounts = GoogleAccounts(signIn: try #require(GoogleSignIn(clientID: clientID, http: fake)), keychain: MemoryKeys())
    let granted = [GoogleCalendarAPI.scope] + (editing ? [GoogleCalendarAPI.editScope] : [])
    try accounts.keep(address: me, refreshToken: "1//shared", granted: Set(granted))
    let calendars = GoogleCalendars(accounts: accounts, store: MemoryBlobs(), rootKey: try .generate(), now: { Dates.date(2026, 11, 8, 12) })
    _ = await calendars.sync()
    return calendars
}

private func key(_ calendars: GoogleCalendars, _ title: String) async throws -> GoogleEventKey {
    let shown = await calendars.events(from: Dates.date(2026, 11, 1), to: Dates.date(2026, 12, 1))
    return try #require(shown.first { $0.title == title }?.google)
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func path(_ request: URLRequest) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
}

private let mountain = TimeZone(identifier: "America/Denver")!

@Suite struct GoogleEventEditingTests {
    @Test func onlyOwnCalendarsCanBeChanged() async throws {
        let fake = FakeGoogleWrites()
        let calendars = try await setUp(fake)
        // Shared ones the person can write to, and subscribed ones, stay read-only (decision 3).
        #expect(await calendars.targets().map(\.title) == ["Personal"])
        let lunch = GoogleEventBody(title: "Lunch", location: "", notes: "", start: Dates.date(2026, 11, 12, 12), end: Dates.date(2026, 11, 12, 13), isAllDay: false)
        await #expect(throws: GoogleCalendarProblem.notAllowed) {
            try await calendars.create(lunch, in: GoogleTarget(account: me, calendar: family, title: "Clemens family"))
        }
        #expect(fake.changes.isEmpty)
    }

    @Test func createSendsTheEventAndEmailsNobody() async throws {
        let fake = FakeGoogleWrites()
        let calendars = try await setUp(fake)
        let target = try #require(await calendars.targets().first)
        let body = GoogleEventBody(
            title: "Piano lesson", location: "Maple Music, 22 Center St", notes: "Bring the Czerny book.",
            start: Dates.date(2026, 11, 12, 16), end: Dates.date(2026, 11, 12, 17), isAllDay: false,
            repeatRule: RepeatRule(frequency: .weekly, until: CalendarDay(year: 2026, month: 12, day: 17)), timeZone: mountain
        )
        try await calendars.create(body, in: target)
        let request = try #require(fake.changes.first)
        #expect(request.httpMethod == "POST")
        #expect(path(request) == "/calendar/v3/calendars/mckay.clemens%40gmail.com/events")
        #expect(request.url?.query == "sendUpdates=none")
        #expect(request.value(forHTTPHeaderField: "If-Match") == nil)
        let sent = try json(request)
        #expect(sent["summary"] as? String == "Piano lesson")
        #expect(sent["attendees"] == nil)
        #expect((sent["start"] as? [String: String])?["timeZone"] == "America/Denver")
        // The last lesson is on the 17th, so the rule runs to the end of that day in Denver, in UTC.
        #expect(sent["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;UNTIL=20261218T065959Z"])
    }

    @Test func allDayGoesAsGooglesDates() {
        let body = GoogleEventBody(title: "Moab trip", location: "", notes: "", start: Dates.date(2026, 11, 20, zone: "GMT"), end: Dates.date(2026, 11, 22, zone: "GMT"), isAllDay: true)
        let sent = body.json()
        #expect(sent["start"] as? [String: String] == ["date": "2026-11-20"])
        // Google's end is the day after the last.
        #expect(sent["end"] as? [String: String] == ["date": "2026-11-23"])
    }

    @Test func anEditSendsOnlyWhatChangedWithItsVersion() async throws {
        let fake = FakeGoogleWrites()
        fake.events = [dentist]
        let calendars = try await setUp(fake)
        let visit = try await key(calendars, "Dentist, Dr. Okafor")
        #expect(visit.canEdit && visit.event.hasGuests)
        var body = GoogleEventBody(
            title: "Dentist, moved", location: visit.event.location, notes: visit.event.notes,
            start: visit.event.start, end: visit.event.end, isAllDay: false
        )
        try await calendars.update(visit, with: body, scope: .thisOccurrence)
        let request = try #require(fake.changes.first)
        #expect(request.httpMethod == "PATCH")
        #expect(path(request)?.hasSuffix("/events/4kq2v8dentist") == true)
        #expect(request.url?.query == "sendUpdates=none")
        #expect(request.value(forHTTPHeaderField: "If-Match") == "\"3381920000000000\"")
        // Untouched notes keep Google's formatting, and guests are never sent.
        let sent = try json(request)
        #expect(Set(sent.keys) == ["summary"])

        body = GoogleEventBody(title: visit.event.title, location: visit.event.location, notes: visit.event.notes, start: visit.event.start, end: visit.event.end, isAllDay: false)
        try await calendars.update(visit, with: body, scope: .thisOccurrence)
        #expect(fake.changes.count == 1, "Nothing changed, so nothing is sent")
    }

    @Test func aNewerVersionOnGoogleIsNeverOverwritten() async throws {
        let fake = FakeGoogleWrites()
        fake.events = [dentist]
        let calendars = try await setUp(fake)
        let visit = try await key(calendars, "Dentist, Dr. Okafor")
        fake.writeStatus = 412
        let body = GoogleEventBody(title: "Dentist, moved", location: "", notes: "", start: visit.event.start, end: visit.event.end, isAllDay: false)
        await #expect(throws: GoogleCalendarProblem.changedOnGoogle) {
            try await calendars.update(visit, with: body, scope: .thisOccurrence)
        }
        await #expect(throws: GoogleCalendarProblem.changedOnGoogle) {
            try await calendars.delete(visit, scope: .thisOccurrence)
        }
    }

    @Test func movingEveryOccurrenceMovesTheSeriesByTheSameAmount() async throws {
        let fake = FakeGoogleWrites()
        fake.events = [standup]
        fake.series = [
            "etag": "\"3381920000000999\"",
            "start": ["dateTime": "2026-09-01T09:00:00-06:00", "timeZone": "America/Denver"],
            "end": ["dateTime": "2026-09-01T09:15:00-06:00", "timeZone": "America/Denver"],
        ]
        let calendars = try await setUp(fake)
        let meeting = try await key(calendars, "Team standup")
        #expect(meeting.repeats)
        let body = GoogleEventBody(
            title: "Team standup", location: "", notes: "",
            start: meeting.event.start.addingTimeInterval(1_800), end: meeting.event.end.addingTimeInterval(1_800), isAllDay: false
        )
        try await calendars.update(meeting, with: body, scope: .allOccurrences)
        let request = try #require(fake.changes.first)
        #expect(path(request)?.hasSuffix("/events/9wkstandup") == true)
        #expect(request.value(forHTTPHeaderField: "If-Match") == "\"3381920000000999\"")
        let sent = try json(request)
        let start = try #require(sent["start"] as? [String: String])
        #expect(start["dateTime"] == "2026-09-01T15:30:00Z")
        #expect(start["timeZone"] == "America/Denver")
    }

    @Test func deletingOneOccurrenceOrTheSeries() async throws {
        let fake = FakeGoogleWrites()
        fake.events = [standup]
        fake.series = ["etag": "\"3381920000000999\"", "start": ["dateTime": "2026-09-01T09:00:00-06:00"], "end": ["dateTime": "2026-09-01T09:15:00-06:00"]]
        let calendars = try await setUp(fake)
        let meeting = try await key(calendars, "Team standup")
        try await calendars.delete(meeting, scope: .thisOccurrence)
        try await calendars.delete(meeting, scope: .allOccurrences)
        #expect(fake.changes.map(\.httpMethod) == ["DELETE", "DELETE"])
        #expect(path(fake.changes[0])?.hasSuffix("/events/9wkstandup_20261111T160000Z") == true)
        #expect(path(fake.changes[1])?.hasSuffix("/events/9wkstandup") == true)
        #expect(fake.changes.allSatisfy { $0.url?.query == "sendUpdates=none" })
        // Already gone at Google is fine.
        fake.writeStatus = 410
        try await calendars.delete(meeting, scope: .thisOccurrence)
    }

    @Test func withoutEditingAllowedNothingIsSent() async throws {
        let fake = FakeGoogleWrites()
        fake.events = [dentist]
        let calendars = try await setUp(fake, editing: false)
        #expect(await calendars.targets().isEmpty)
        let visit = try await key(calendars, "Dentist, Dr. Okafor")
        #expect(!visit.canEdit && visit.canAllowEditing)
        await #expect(throws: GoogleCalendarProblem.notAllowed) {
            try await calendars.delete(visit, scope: .thisOccurrence)
        }
        #expect(fake.changes.isEmpty)
        // Allowing it is one consent tap on the same account, asking for both Calendar scopes.
        let page = try #require(await calendars.editingAuthorization(for: me))
        #expect(Set(page.scopes).isSuperset(of: [GoogleCalendarAPI.scope, GoogleCalendarAPI.editScope]))
        #expect(page.account == me)
    }

    @Test func offlineSendsNothingLater() async throws {
        let fake = FakeGoogleWrites()
        let calendars = try await setUp(fake)
        let target = try #require(await calendars.targets().first)
        fake.offline = true
        let body = GoogleEventBody(title: "Lunch", location: "", notes: "", start: Dates.date(2026, 11, 12, 12), end: Dates.date(2026, 11, 12, 13), isAllDay: false)
        await #expect(throws: GoogleCalendarProblem.offline) { try await calendars.create(body, in: target) }
        fake.offline = false
        _ = await calendars.sync()
        // Nothing was queued to go later (decision 7).
        #expect(fake.changes.count == 1)
    }

    @MainActor
    @Test func nothingReachesGoogleBeforeThePress() async throws {
        let fake = FakeGoogleWrites()
        fake.events = [dentist]
        let accounts = GoogleAccounts(signIn: try #require(GoogleSignIn(clientID: clientID, http: fake)), keychain: MemoryKeys())
        try accounts.keep(address: me, refreshToken: "1//shared", granted: [GoogleCalendarAPI.scope, GoogleCalendarAPI.editScope])
        let rootKey = try ContentRootKey.generate()
        let google = GoogleCalendars(accounts: accounts, store: MemoryBlobs(), rootKey: rootKey, now: { Dates.date(2026, 11, 8, 12) })
        let model = CalendarModel(
            vault: CalendarVault(store: MemoryBlobs(), rootKey: rootKey), devices: FakeDevices(), reminders: FakeReminders(),
            google: google, startingMode: .month, display: Dates.calendar(),
            defaults: try #require(UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")), now: { Dates.date(2026, 11, 8, 12) }
        )
        await model.load()
        await model.refreshGoogle()
        fake.allowWrites = false
        let target = try #require(model.googleTargets.first)
        var draft = EventDraft(start: Dates.date(2026, 11, 12, 16), end: Dates.date(2026, 11, 12, 17))
        draft.title = "Piano lesson"
        let change = try #require(model.googleChange(draft, to: target))
        #expect(change.account == me && change.calendarTitle == "Personal" && change.body.title == "Piano lesson")
        #expect(fake.changes.isEmpty)

        // The press.
        fake.allowWrites = true
        #expect(await model.send(change) == nil)
        #expect(fake.changes.count == 1)
    }
}

@Suite struct GoogleEventEditingTwoUserTests {
    @Test("User 2 can't change user 1's Google events, and nothing user 1 typed is readable at rest")
    func user2CannotChange() async throws {
        let fake = FakeGoogleWrites()
        fake.events = [dentist]
        let store = MemoryBlobs()
        let keys = MemoryKeys()
        let accounts = GoogleAccounts(signIn: try #require(GoogleSignIn(clientID: clientID, http: fake)), keychain: keys)
        try accounts.keep(address: me, refreshToken: "1//shared", granted: [GoogleCalendarAPI.scope, GoogleCalendarAPI.editScope])
        let mine = GoogleCalendars(accounts: accounts, store: store, rootKey: try .generate(), now: { Dates.date(2026, 11, 8, 12) })
        _ = await mine.sync()
        let visit = try await key(mine, "Dentist, Dr. Okafor")
        let body = GoogleEventBody(title: "Dentist, Thursday 3pm", location: "418 Elm Street", notes: "", start: visit.event.start, end: visit.event.end, isAllDay: false)
        try await mine.update(visit, with: body, scope: .thisOccurrence)
        for text in ["Dentist", "Okafor", "Elm Street", "Thursday", "mckay"] {
            #expect(store.everything.range(of: Data(text.utf8)) == nil)
        }

        // User 2, on the same storage with their own key and no Google connection of user 1's.
        let theirAccounts = GoogleAccounts(signIn: try #require(GoogleSignIn(clientID: clientID, http: fake)), keychain: MemoryKeys())
        let theirs = GoogleCalendars(accounts: theirAccounts, store: store, rootKey: try .generate(), now: { Dates.date(2026, 11, 8, 12) })
        #expect(await theirs.targets().isEmpty)
        let before = fake.changes.count
        await #expect(throws: (any Error).self) { try await theirs.delete(visit, scope: .thisOccurrence) }
        #expect(fake.changes.count == before)
    }
}
