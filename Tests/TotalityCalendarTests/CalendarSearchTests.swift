import Foundation
import Testing
import TotalityCore
@testable import TotalityCalendar

@Suite struct CalendarSearchTests {
    private let display = Dates.calendar()
    private let now = Dates.date(2026, 10, 15, 8, 30)

    private func hits(
        _ query: String, _ events: [CalendarEvent], device: [DeviceEvent] = [],
        display: Calendar? = nil, now: Date? = nil
    ) -> [SearchHit] {
        CalendarSearch.hits(
            terms: SearchText.terms(in: query), events: events, deviceEvents: device,
            display: display ?? self.display, now: now ?? self.now
        )
    }

    private func dentist() -> CalendarEvent {
        let id = UUID()
        let lease = ContentRef(module: .reader, kind: .note, id: id, keyRef: .crk(objectID: id), preview: .init(title: "Lisbon lease"))
        return CalendarEvent(
            title: "Dentist", location: "14 Main Street", notes: "Bring the insurance card.",
            start: Dates.date(2026, 10, 20, 9), end: Dates.date(2026, 10, 20, 10),
            timeZoneID: "America/Denver", attachments: [lease]
        )
    }

    private func device(
        _ id: String, _ title: String = "Budget review", on start: Date, location: String = "", notes: String = "", calendar: String = "Work"
    ) -> DeviceEvent {
        DeviceEvent(
            id: id, title: title, location: location, notes: notes, start: start,
            end: start.addingTimeInterval(3_600), isAllDay: false, calendarTitle: calendar
        )
    }

    @Test("Titles, locations, notes, and attached item names are all found")
    func fields() {
        let event = dentist()
        for query in ["DENTIST", "main street", "insurance", "lisbon lease"] {
            #expect(hits(query, [event]).count == 1, "\(query)")
        }
        #expect(hits("orthodontist", [event]).isEmpty)
    }

    @Test("Every word has to appear, in any field")
    func everyWord() {
        #expect(hits("insurance dentist lease", [dentist()]).count == 1)
        #expect(hits("insurance gym", [dentist()]).isEmpty)
    }

    @Test("Results say what the match was, unless it was the title")
    func snippets() {
        let event = dentist()
        #expect(hits("dentist", [event]).first?.snippet == nil)
        #expect(hits("insurance", [event]).first?.snippet == "Bring the insurance card.")
        #expect(hits("lease", [event]).first?.snippet == "Lisbon lease")
    }

    @Test("A result opens by the same ID the Calendar's lists use")
    func identity() throws {
        let event = dentist()
        let hit = try #require(hits("dentist", [event]).first)
        let occurrence = try #require(CalendarSearch.occurrence(of: event, display: display, now: now))
        #expect(hit.itemID == CalendarEntry(source: .own(occurrence)).id)
        #expect(hit.module == .calendar)
    }

    @Test("A repeating event shows once, at its next occurrence")
    func repeats() {
        let weekly = Dates.event(Dates.date(2026, 10, 1, 9), title: "Standup", rule: .init(frequency: .weekly))
        let found = hits("standup", [weekly])
        #expect(found.count == 1)
        #expect(found.first?.date == Dates.date(2026, 10, 15, 9))
    }

    @Test("An occurrence happening now is still the one to open, and an ended one isn't")
    func nextMovesOn() {
        let weekly = Dates.event(Dates.date(2026, 10, 1, 9), title: "Standup", rule: .init(frequency: .weekly))
        #expect(hits("standup", [weekly], now: Dates.date(2026, 10, 15, 9, 30)).first?.date == Dates.date(2026, 10, 15, 9))
        #expect(hits("standup", [weekly], now: Dates.date(2026, 10, 15, 11)).first?.date == Dates.date(2026, 10, 22, 9))
    }

    @Test("A series that's over shows its last occurrence")
    func finishedSeries() {
        let rule = RepeatRule(frequency: .weekly, until: CalendarDay(year: 2026, month: 10, day: 8))
        let series = Dates.event(Dates.date(2026, 9, 1, 9), title: "Physio", rule: rule)
        #expect(hits("physio", [series]).first?.date == Dates.date(2026, 10, 6, 9))
    }

    @Test("A repeating event far off is still found, at its first occurrence")
    func farAhead() {
        let start = Dates.date(2029, 3, 1, 9)
        #expect(hits("standup", [Dates.event(start, rule: .init(frequency: .yearly))]).first?.date == start)
    }

    @Test("An event from years ago is still found")
    func longAgo() {
        let start = Dates.date(2019, 5, 2, 9)
        #expect(hits("wedding", [Dates.event(start, title: "Wedding")]).first?.date == start)
    }

    @Test("An event with every occurrence removed shows nothing")
    func nothingLeft() {
        var event = Dates.event(Dates.date(2026, 10, 20, 9), title: "Standup")
        event.skipped = [event.start]
        #expect(hits("standup", [event]).isEmpty)
    }

    @Test("What's coming goes first, soonest first, then the past, latest first")
    func order() {
        let found = hits("review", [
            Dates.event(Dates.date(2026, 9, 1, 9), title: "September review"),
            Dates.event(Dates.date(2026, 12, 1, 9), title: "December review"),
            Dates.event(Dates.date(2026, 10, 1, 9), title: "October review"),
            Dates.event(Dates.date(2026, 11, 1, 9), title: "November review"),
        ])
        #expect(found.map(\.title) == ["November review", "December review", "October review", "September review"])
    }

    @Test("An all-day event lands on its own day, wherever the person is")
    func allDay() throws {
        let tokyo = Dates.calendar("Asia/Tokyo")
        let hit = try #require(hits("trip", [Dates.allDay(2026, 10, 20)], display: tokyo).first)
        #expect(hit.date == Dates.date(2026, 10, 20, zone: "Asia/Tokyo"))
        #expect(hit.detail?.contains("Oct 20") == true)
    }

    @Test("An all-day event today counts as coming, even late in the day")
    func allDayToday() {
        let found = hits("trip", [
            Dates.event(Dates.date(2026, 10, 15, 7), title: "Trip planning"),
            Dates.allDay(2026, 10, 15),
        ], now: Dates.date(2026, 10, 15, 22))
        #expect(found.map(\.title) == ["Trip", "Trip planning"])
    }

    @Test("A timed result gives its time, in the person's zone")
    func writtenTime() throws {
        let hit = try #require(hits("dentist", [dentist()], display: Dates.calendar("Europe/Lisbon")).first)
        #expect(hit.detail?.contains("Oct 20") == true)
        #expect(hit.detail?.contains("4:00") == true)
    }

    @Test("An all-day result gives no time")
    func allDayHasNoTime() throws {
        let detail = try #require(hits("trip", [Dates.allDay(2026, 10, 20)]).first?.detail)
        #expect(!detail.contains("12:00"))
        #expect(!detail.contains("AM"))
    }

    @Test("Device events are found by title, location, and notes")
    func deviceFields() {
        let event = device("1", on: Dates.date(2026, 10, 20, 9), location: "Room 4", notes: "Bring the forecast.")
        for query in ["budget", "room", "forecast"] {
            #expect(hits(query, [], device: [event]).count == 1, "\(query)")
        }
        #expect(hits("forecast", [], device: [event]).first?.snippet == "Bring the forecast.")
        #expect(hits("budget", [], device: [event]).first?.itemID == "device-1")
    }

    @Test("A device calendar's repeats show once, at the next one")
    func deviceRepeats() throws {
        let found = hits("budget", [], device: [
            device("1", on: Dates.date(2026, 10, 8, 9), notes: "Last week's numbers"),
            device("2", on: Dates.date(2026, 10, 22, 9), notes: "Next week's numbers"),
            device("3", on: Dates.date(2026, 10, 29, 9)),
        ])
        #expect(found.map(\.itemID) == ["device-2"])
    }

    @Test("A device series that's over shows its latest")
    func deviceFinished() {
        let found = hits("budget", [], device: [
            device("1", on: Dates.date(2026, 9, 8, 9)),
            device("2", on: Dates.date(2026, 10, 8, 9)),
        ])
        #expect(found.map(\.itemID) == ["device-2"])
    }

    @Test("The snippet comes from the occurrence shown")
    func deviceSnippet() {
        let found = hits("numbers", [], device: [
            device("1", on: Dates.date(2026, 10, 8, 9), notes: "Last week's numbers"),
            device("2", on: Dates.date(2026, 10, 22, 9), notes: "Next week's numbers"),
        ])
        #expect(found.first?.snippet == "Next week's numbers")
    }

    @Test("The same name in two calendars is two events")
    func deviceCalendars() {
        let found = hits("budget", [], device: [
            device("1", on: Dates.date(2026, 10, 20, 9), calendar: "Work"),
            device("2", on: Dates.date(2026, 10, 21, 9), calendar: "Home"),
        ])
        #expect(found.count == 2)
    }

    @Test("Own and device events share one order")
    func mixedOrder() {
        let found = hits("review", [Dates.event(Dates.date(2026, 10, 20, 9), title: "Own review")], device: [
            device("1", "Device review", on: Dates.date(2026, 10, 18, 9)),
        ])
        #expect(found.map(\.title) == ["Device review", "Own review"])
    }
}

@MainActor
@Suite struct CalendarModuleSearchTests {
    private let devices = FakeDevices()
    private let now = Dates.date(2026, 10, 15, 8, 30)

    private func vault() throws -> CalendarVault {
        CalendarVault(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
    }

    private func module(_ vault: CalendarVault?, hidden: Set<String> = []) -> CalendarModule {
        let now = now
        return CalendarModule(vault: vault, devices: devices, hidden: { hidden }, display: Dates.calendar(), now: { now })
    }

    private func model(_ vault: CalendarVault) -> CalendarModel {
        let now = now
        return CalendarModel(
            vault: vault, devices: devices, reminders: FakeReminders(), registry: nil, startingMode: .schedule,
            display: Dates.calendar(), defaults: UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!, now: { now }
        )
    }

    private func allowDevices() {
        devices.state = .allowed
        devices.available = [
            DeviceCalendar(id: "work", title: "Work", account: "iCloud"),
            DeviceCalendar(id: "home", title: "Home", account: "Google"),
        ]
        devices.stored = [DeviceEvent(
            id: "1", title: "Budget review", location: "", notes: "", start: Dates.date(2026, 10, 20, 13),
            end: Dates.date(2026, 10, 20, 14), isAllDay: false, calendarTitle: "Work"
        )]
    }

    @Test("Saved events are searched from the sealed vault")
    func ownEvents() async throws {
        let vault = try vault()
        try await vault.save(Dates.event(Dates.date(2026, 10, 20, 9), title: "Dentist"))
        #expect(try await module(vault).search("dentist").map(\.title) == ["Dentist"])
        #expect(try await module(vault).search("gym").isEmpty)
    }

    @Test("Only calendars still turned on are read, a year either side of today")
    func hiddenCalendars() async throws {
        allowDevices()
        #expect(try await module(try vault(), hidden: ["home"]).search("budget").map(\.title) == ["Budget review"])
        #expect(devices.askedFor.last == ["work"])
        let range = try #require(devices.askedBetween)
        #expect(range.start == CalendarDay(year: 2025, month: 10, day: 14).start(in: Dates.calendar()))
        #expect(range.end == CalendarDay(year: 2027, month: 10, day: 16).start(in: Dates.calendar()))
    }

    @Test("Every calendar hidden means no device results")
    func allHidden() async throws {
        allowDevices()
        #expect(try await module(try vault(), hidden: ["work", "home"]).search("budget").isEmpty)
    }

    @Test("Device calendars stay out of it without the person's permission")
    func noPermission() async throws {
        allowDevices()
        devices.state = .denied
        #expect(try await module(try vault()).search("budget").isEmpty)
    }

    @Test("Before any vault exists there's nothing to find, and nothing goes wrong")
    func noVault() async throws {
        allowDevices()
        #expect(try await module(nil).search("budget").isEmpty)
        #expect(try await CalendarModule().search("budget").isEmpty)
    }

    @Test("Hidden calendars are read from where the Calendar keeps them")
    func hiddenStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)"))
        #expect(CalendarModel.hiddenCalendars(in: defaults).isEmpty)
        let model = CalendarModel(
            vault: try vault(), devices: devices, reminders: FakeReminders(), registry: nil, startingMode: .schedule,
            display: Dates.calendar(), defaults: defaults, now: { Date() }
        )
        allowDevices()
        model.setVisible(false, calendar: DeviceCalendar(id: "work", title: "Work", account: "iCloud"))
        #expect(CalendarModel.hiddenCalendars(in: defaults) == ["work"])
    }

    @Test("User 2 searching the same storage finds none of user 1's events")
    func secondUser() async throws {
        let blobs = MemoryBlobs()
        let first = CalendarVault(store: blobs, rootKey: try ContentRootKey.generate())
        let second = CalendarVault(store: blobs, rootKey: try ContentRootKey.generate())
        try await first.save(Dates.event(Dates.date(2026, 10, 20, 9), title: "Dentist"))
        #expect(try await module(first).search("dentist").count == 1)
        #expect(try await module(second).search("dentist").isEmpty)
    }

    @Test("A result opens on its own day, even months from the one on screen")
    func opensFarAway() async throws {
        let vault = try vault()
        let event = Dates.event(Dates.date(2027, 6, 3, 9), title: "Dentist")
        try await vault.save(event)
        let model = model(vault)
        await model.load()
        model.requestedHit = try #require(try await module(vault).search("dentist").first)
        let entry = try #require(model.takeRequestedEntry())
        #expect(entry.title == "Dentist")
        #expect(model.selectedDay == CalendarDay(year: 2027, month: 6, day: 3))
        #expect(model.requestedHit == nil)
        #expect(model.notice == nil)
    }

    @Test("A repeating result opens the occurrence it showed")
    func opensOccurrence() async throws {
        let vault = try vault()
        try await vault.save(Dates.event(Dates.date(2026, 10, 1, 9), title: "Standup", rule: .init(frequency: .weekly)))
        let model = model(vault)
        await model.load()
        model.requestedHit = try #require(try await module(vault).search("standup").first)
        #expect(model.takeRequestedEntry()?.start == Dates.date(2026, 10, 15, 9))
    }

    @Test("An all-day result opens on its day")
    func opensAllDay() async throws {
        let vault = try vault()
        try await vault.save(Dates.allDay(2026, 11, 2))
        let model = model(vault)
        await model.load()
        model.requestedHit = try #require(try await module(vault).search("trip").first)
        #expect(model.takeRequestedEntry()?.title == "Trip")
        #expect(model.selectedDay == CalendarDay(year: 2026, month: 11, day: 2))
    }

    @Test("A device result opens too")
    func opensDevice() async throws {
        allowDevices()
        let vault = try vault()
        let model = model(vault)
        await model.load()
        model.requestedHit = try #require(try await module(vault).search("budget").first)
        #expect(model.takeRequestedEntry()?.title == "Budget review")
    }

    @Test("A result that's gone by the time it's opened says so")
    func gone() async throws {
        let vault = try vault()
        let event = Dates.event(Dates.date(2026, 10, 20, 9), title: "Dentist")
        try await vault.save(event)
        let hit = try #require(try await module(vault).search("dentist").first)
        try await vault.delete(event.id)
        let model = model(vault)
        await model.load()
        model.requestedHit = hit
        #expect(model.takeRequestedEntry() == nil)
        #expect(model.notice == "This event is no longer here.")
    }

    @Test("Opening the Calendar normally does nothing")
    func nothingRequested() async throws {
        let model = model(try vault())
        await model.load()
        let day = model.selectedDay
        #expect(model.takeRequestedEntry() == nil)
        #expect(model.selectedDay == day)
        #expect(model.notice == nil)
    }
}

@MainActor
@Suite struct CalendarHomeTileTests {
    private let devices = FakeDevices()

    private func model(firstWeekday: Int = 1) throws -> (CalendarModel, CalendarVault) {
        var display = Dates.calendar()
        display.firstWeekday = firstWeekday
        let vault = CalendarVault(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
        let model = CalendarModel(
            vault: vault, devices: devices, reminders: FakeReminders(), registry: nil, startingMode: .month, display: display,
            defaults: UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!, now: { Dates.date(2026, 10, 15, 8, 30) }
        )
        return (model, vault)
    }

    @Test("This week runs from where the device starts its week")
    func week() throws {
        // October 15, 2026 is a Thursday.
        #expect(try model(firstWeekday: 1).0.thisWeek.map(\.day) == [11, 12, 13, 14, 15, 16, 17])
        #expect(try model(firstWeekday: 2).0.thisWeek.map(\.day) == [12, 13, 14, 15, 16, 17, 18])
    }

    @Test("The weekday letters start the same way")
    func letters() throws {
        #expect(try model(firstWeekday: 1).0.weekdayLetters == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(try model(firstWeekday: 2).0.weekdayLetters == ["M", "T", "W", "T", "F", "S", "S"])
    }

    @Test("A week crossing into last month still knows what's on")
    func weekAcrossMonths() async throws {
        var display = Dates.calendar()
        display.firstWeekday = 1
        let vault = CalendarVault(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
        // Thursday, October 1, so the week starts on September 27.
        let model = CalendarModel(
            vault: vault, devices: devices, reminders: FakeReminders(), registry: nil, startingMode: .month, display: display,
            defaults: UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!, now: { Dates.date(2026, 10, 1, 8, 30) }
        )
        try await vault.save(Dates.event(Dates.date(2026, 9, 28, 9), title: "Dentist"))
        await model.load()
        model.select(CalendarDay(year: 2027, month: 6, day: 15))
        #expect(model.thisWeek.first == CalendarDay(year: 2026, month: 9, day: 27))
        #expect(model.entries(on: CalendarDay(year: 2026, month: 9, day: 28)).map(\.title) == ["Dentist"])
    }

    @Test("Each line on the tile leads to what it's about")
    func linesKnowTheirTargets() async throws {
        let (model, vault) = try model()
        try await vault.save(Dates.event(Dates.date(2026, 10, 15, 10), title: "Dentist"))
        try await vault.save(Dates.event(Dates.date(2026, 10, 15, 17), title: "Dinner"))
        await model.load()
        let lines = try #require(model.glance?.lines)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("Dentist"))
        #expect(lines[1] == "2 things today")
        #expect(lines[2].hasSuffix("Dinner"))
        let titles = (0...2).map { line -> String? in
            guard case .entry(let entry) = model.glanceTarget(at: line) else { return nil }
            return entry.title
        }
        #expect(titles == ["Dentist", nil, "Dinner"])
        #expect(model.glanceTarget(at: 1) == .day(model.today))
        #expect(model.glanceTarget(at: 3) == nil)
    }

    @Test("A quiet day's one line opens today")
    func quietLineOpensToday() async throws {
        let (model, _) = try model()
        await model.load()
        #expect(model.glance?.lines == ["Nothing today"])
        #expect(model.glanceTarget(at: 0) == .day(model.today))
    }

    @Test("A day on the tile opens that day, even though the Calendar starts on its front page")
    func aDayOpensItself() async throws {
        let (model, _) = try model()
        await model.load()
        let day = CalendarDay(year: 2026, month: 10, day: 22)
        model.request(.day(day))
        model.showFront()
        model.takeRequestedDay()
        #expect(model.mode == .day)
        #expect(model.selectedDay == day)
        model.showFront()
        model.takeRequestedDay()
        #expect(model.mode == .month)
    }

    @Test("An event on the tile opens that event")
    func anEventOpensItself() async throws {
        let (model, vault) = try model()
        try await vault.save(Dates.event(Dates.date(2026, 10, 20, 10), title: "Dentist"))
        await model.load()
        let entry = try #require(model.entries(on: CalendarDay(year: 2026, month: 10, day: 20)).first)
        model.request(.entry(entry))
        model.showFront()
        #expect(model.takeRequestedEntry()?.id == entry.id)
        #expect(model.selectedDay == CalendarDay(year: 2026, month: 10, day: 20))
    }

    @Test("The tile's month keeps its events after the Calendar was left on another month")
    func monthStaysThisMonth() async throws {
        let (model, vault) = try model()
        try await vault.save(Dates.event(Dates.date(2026, 10, 2, 9), title: "Dentist"))
        try await vault.save(Dates.event(Dates.date(2026, 10, 30, 9), title: "Physio"))
        await model.load()
        // Past the schedule's reach, so the days are built again.
        model.select(CalendarDay(year: 2027, month: 6, day: 15))
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 2)).map(\.title) == ["Dentist"])
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 30)).map(\.title) == ["Physio"])
    }
}
