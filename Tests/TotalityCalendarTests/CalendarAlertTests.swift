import Foundation
import Testing
import TotalityCore
@testable import TotalityCalendar

/// Several alerts per event, defaults for new events, and the Google events' device-only alerts.
@Suite struct EventAlertTests {
    private let display = Dates.calendar()
    private let now = Dates.date(2026, 10, 15, 8)

    @Test("The single reminder an event was saved with becomes its first alert")
    func existingReminderIsTheFirstAlert() throws {
        var event = Dates.event(Dates.date(2026, 10, 16, 9))
        event.reminderMinutes = 30
        #expect(event.alerts == [30])
        // A saved copy from before alerts existed has no alertMinutes at all.
        let old = try JSONSerialization.data(withJSONObject: [
            "id": event.id.uuidString, "title": "Standup", "location": "", "notes": "", "start": event.start.timeIntervalSinceReferenceDate,
            "end": event.end.timeIntervalSinceReferenceDate, "isAllDay": false, "timeZoneID": "America/Denver", "skipped": [Double](),
            "reminderMinutes": 30, "attachments": [Int](), "createdAt": 0, "updatedAt": 0,
        ])
        #expect(try JSONDecoder().decode(CalendarEvent.self, from: old).alerts == [30])
    }

    @Test("A single alert is stored the old way, so the website and older copies still read it")
    func singleAlertStaysLegacy() {
        var event = Dates.event(Dates.date(2026, 10, 16, 9))
        event.alerts = [15]
        #expect(event.reminderMinutes == 15)
        #expect(event.alertMinutes == nil)
        event.alerts = []
        #expect(event.reminderMinutes == nil)
    }

    @Test func manyAlertsAreKeptEarliestFirstWithNoRepeatsAndAtMostFive() {
        var event = Dates.event(Dates.date(2026, 10, 16, 9))
        event.alerts = [5, 1_440, 30, 30, 60, 10, 0]
        #expect(event.alerts == [1_440, 60, 30, 10, 5])
        #expect(event.reminderMinutes == 1_440)
    }

    @Test("A change to the one reminder from the website wins over an older list")
    func websiteChangeWins() {
        var event = Dates.event(Dates.date(2026, 10, 16, 9))
        event.alerts = [1_440, 30]
        event.reminderMinutes = 5
        #expect(event.alerts == [5])
        event.reminderMinutes = nil
        #expect(event.alerts.isEmpty)
    }

    @Test func eachAlertRingsOnItsOwn() throws {
        var event = Dates.event(Dates.date(2026, 10, 16, 14))
        event.alerts = [1_440, 30, 75]
        let plan = ReminderPlanner.plan(for: [event], now: now, display: display)
        #expect(plan.map(\.fireDate) == [Dates.date(2026, 10, 15, 14), Dates.date(2026, 10, 16, 12, 45), Dates.date(2026, 10, 16, 13, 30)])
        #expect(Set(plan.map(\.id)).count == 3)
        #expect(plan.allSatisfy { $0.title == "Standup" })
    }

    @Test("Alerts already past are left out and the rest still ring")
    func pastAlertsDropOut() {
        var event = Dates.event(Dates.date(2026, 10, 15, 9))
        event.alerts = [120, 15]
        let plan = ReminderPlanner.plan(for: [event], now: now, display: display)
        #expect(plan.map(\.fireDate) == [Dates.date(2026, 10, 15, 8, 45)])
    }

    @Test func allDayAlertsRingAtTheChosenHour() {
        var event = Dates.allDay(2026, 10, 20)
        event.alerts = [10_080, 0]
        let nine = ReminderPlanner.plan(for: [event], now: now, display: display)
        #expect(nine.map(\.fireDate) == [Dates.date(2026, 10, 13, 9), Dates.date(2026, 10, 20, 9)].filter { $0 > now })
        let seven = ReminderPlanner.plan(for: [event], now: now, display: display, allDayMinute: 7 * 60 + 30)
        #expect(seven.map(\.fireDate) == [Dates.date(2026, 10, 20, 7, 30)])
        #expect(seven.first?.body == "All day")
    }

    @Test("Going over the limit keeps the soonest and counts what was left out")
    func skippedAreCounted() {
        var event = Dates.event(Dates.date(2026, 10, 15, 12), rule: .init(frequency: .daily))
        event.alerts = [0, 5]
        let result = ReminderPlanner.planning(for: [event], now: now, display: display)
        #expect(result.planned.count == ReminderPlanner.limit)
        #expect(result.skipped > 0)
        #expect(result.planned.map(\.fireDate) == result.planned.map(\.fireDate).sorted())
    }

    @Test("Only the title and time reach the operating system, and a tap carries only an ID")
    func nothingPrivateLeaks() throws {
        var event = Dates.event(Dates.date(2026, 10, 16, 9), title: "Checkup")
        event.alerts = [60, 10]
        event.location = "Riverside Clinic"
        event.notes = "Bring the referral letter"
        for planned in ReminderPlanner.plan(for: [event], now: now, display: display) {
            #expect(!planned.body.contains("Riverside"))
            #expect(!planned.body.contains("referral"))
            #expect(!planned.id.contains("Checkup"))
            #expect(planned.openItem?.contains("Checkup") == false)
        }
    }

    @Test("Google's events get alerts on this iPhone only")
    func googleAlertsAreDeviceOnly() {
        let start = Dates.date(2026, 10, 16, 15)
        let google = DeviceEvent(
            id: "google-abc", title: "Lunch", location: "Cafe", notes: "", start: start, end: start.addingTimeInterval(3_600),
            isAllDay: false, calendarTitle: "Personal", origin: .google(account: "me@example.com", link: nil)
        )
        let apple = DeviceEvent(id: "ek-1", title: "Gym", location: "", notes: "", start: start, end: start.addingTimeInterval(3_600), isAllDay: false, calendarTitle: "Home")
        let plan = ReminderPlanner.plan(
            for: [], now: now, display: display, device: [google, apple], deviceAlerts: ["google-abc": [1_440, 10], "ek-1": [10]]
        )
        #expect(plan.map(\.fireDate) == [Dates.date(2026, 10, 15, 15), Dates.date(2026, 10, 16, 14, 50)])
        #expect(plan.allSatisfy { $0.title == "Lunch" && $0.openItem == nil })
    }
}

@Suite @MainActor struct EventAlertModelTests {
    private let blobs = MemoryBlobs()
    private let reminders = FakeReminders()

    private func model(defaults settings: CalendarAlertDefaults = CalendarAlertDefaults()) throws -> CalendarModel {
        let model = CalendarModel(
            vault: CalendarVault(store: blobs, rootKey: try ContentRootKey.generate()), devices: FakeDevices(), reminders: reminders,
            startingMode: .schedule, display: Dates.calendar(), defaults: UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!,
            now: { Dates.date(2026, 10, 15, 8, 30) }
        )
        model.alertDefaults = { settings }
        return model
    }

    @Test("A new event starts with the defaults. Switching to all-day swaps them while they're untouched")
    func newEventsGetDefaults() throws {
        let model = try model()
        var draft = model.newDraft()
        #expect(draft.alerts == [15])
        draft.alerts = model.alertsAfterSwitching(draft.alerts, toAllDay: true)
        #expect(draft.alerts == [0])
        // Alerts the person changed stay as they are.
        #expect(model.alertsAfterSwitching([5], toAllDay: true) == [5])
    }

    @Test("Defaults change new events only")
    func existingEventsKeepTheirAlerts() async throws {
        var settings = CalendarAlertDefaults()
        let model = try model(defaults: settings)
        var first = model.newDraft(on: CalendarDay(year: 2026, month: 10, day: 16), hour: 9)
        first.title = "Dentist"
        #expect(await model.create(first))
        settings.timed = [60]
        model.alertDefaults = { settings }
        #expect(model.newDraft(on: CalendarDay(year: 2026, month: 10, day: 17), hour: 9).alerts == [60])
        let kept = try #require(model.events.first)
        #expect(kept.alerts == [15])
    }

    @Test("Saving with several alerts schedules each, and deleting clears them")
    func severalAlertsFollowSavesAndDeletes() async throws {
        let model = try model()
        var draft = model.newDraft(on: CalendarDay(year: 2026, month: 10, day: 16), hour: 9)
        draft.title = "Flight"
        draft.alerts = [1_440, 120, 30]
        #expect(await model.create(draft))
        #expect(await reminders.asked == 1)
        #expect(await reminders.current.count == 3)
        #expect(model.skippedAlerts == 0)
        let saved = try #require(model.events.first)
        #expect(saved.alerts == [1_440, 120, 30])
        let occurrence = try #require(saved.occurrences(from: CalendarDay(year: 2026, month: 10, day: 16), through: CalendarDay(year: 2026, month: 10, day: 16), in: model.display).first)
        await model.delete(occurrence, scope: .allOccurrences)
        #expect(await reminders.current.isEmpty)
    }

    @Test("A person who removes every alert gets none, and is never asked for permission")
    func noAlertsNoPrompt() async throws {
        let model = try model()
        var draft = model.newDraft(on: CalendarDay(year: 2026, month: 10, day: 16), hour: 9)
        draft.alerts = []
        #expect(await model.create(draft))
        #expect(await reminders.asked == 0)
        #expect(await reminders.current.isEmpty)
    }

    @Test("A tap on an alert asks for that occurrence")
    func tapOpensTheEvent() throws {
        let model = try model()
        let event = Dates.event(Dates.date(2026, 10, 16, 14))
        let occurrence = EventOccurrence(event: event, start: event.start, end: event.end)
        model.requestAlertTarget(occurrence.id)
        #expect(model.requestedHit?.itemID == occurrence.id)
        #expect(model.requestedHit?.date == event.start)
    }

    @Test("Alerts on a Google event are kept on this device, by offsets only")
    func googleAlertsStayOnTheDevice() async throws {
        let suite = "totality.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = CalendarModel(
            vault: CalendarVault(store: blobs, rootKey: try ContentRootKey.generate()), devices: FakeDevices(), reminders: reminders,
            display: Dates.calendar(), defaults: defaults, now: { Dates.date(2026, 10, 15, 8, 30) }
        )
        let key = GoogleEventKey(
            account: "me@example.com", calendar: "primary", calendarTitle: "Personal",
            event: GoogleCalendarEvent(
                id: "evt1", title: "Lunch", location: "", notes: "", start: Dates.date(2026, 10, 16, 12),
                end: Dates.date(2026, 10, 16, 13), isAllDay: false, link: nil, etag: "e"
            ),
            canEdit: true, canAllowEditing: false
        )
        await model.setDeviceAlerts([60, 10], for: key)
        #expect(model.deviceAlerts(for: key) == [60, 10])
        #expect(model.draft(for: key).alerts == [60, 10])
        let stored = defaults.dictionary(forKey: "calendar.deviceAlerts") as? [String: [Int]]
        #expect(stored?.values.first == [60, 10])
        #expect(!String(describing: stored).contains("Lunch"))
        await model.setDeviceAlerts([], for: key)
        #expect(model.deviceAlerts(for: key).isEmpty)
    }
}

/// Calendar's case of the two-user test (definition of done): user B can't read user A's events or their
/// alerts, and none of it is readable where it's kept. The server side is in backend-tests/two-user.test.js.
@Suite struct CalendarAlertsTwoUserTests {
    @Test func anotherPersonCantReadAnEventsAlerts() async throws {
        let store = MemoryBlobs()
        let a = CalendarVault(store: store, rootKey: try ContentRootKey.generate())
        let b = CalendarVault(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
        var event = Dates.event(Dates.date(2026, 10, 16, 9), title: "Oncology follow-up")
        event.alerts = [1_440, 30, 75]
        try await a.save(event)

        // Nothing readable at rest: no title, and no sign of how many alerts or when.
        #expect(store.everything.range(of: Data("Oncology".utf8)) == nil)
        #expect(store.everything.range(of: Data("alertMinutes".utf8)) == nil)
        #expect(store.everything.range(of: Data("reminderMinutes".utf8)) == nil)

        // A's own device reads them back.
        let mine = try #require(try await a.list().events.first)
        #expect(mine.alerts == [1_440, 75, 30])

        // B is handed A's record, as a server could, and can't open it.
        let sealed = try #require(try await a.sealedObject(event.id))
        await #expect(throws: (any Error).self) { try await b.store(sealed, ifLocalHash: nil) }
        #expect(try await b.list().events.isEmpty)
    }
}
