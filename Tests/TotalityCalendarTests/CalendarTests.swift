import Foundation
import Testing
import TotalityCore
@testable import TotalityCalendar

final class MemoryBlobs: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    var everything: Data { lock.withLock { blobs.values.reduce(Data(), +) } }
    func corrupt(_ name: String) { lock.withLock { blobs[name]?[30] ^= 0xFF } }
}

final class MemoryKeys: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    func load(_ name: String) throws -> Data? { lock.withLock { secrets[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { secrets[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
}

final class FakeDevices: DeviceCalendarSource, @unchecked Sendable {
    var state = DeviceCalendarAccess.notAsked
    var grants = true
    var available: [DeviceCalendar] = []
    var stored: [DeviceEvent] = []
    private(set) var askedFor: [Set<String>] = []

    func access() -> DeviceCalendarAccess { state }
    func requestAccess() async -> Bool {
        state = grants ? .allowed : .denied
        return grants
    }
    func calendars() -> [DeviceCalendar] { state == .allowed ? available : [] }
    func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [DeviceEvent] {
        askedFor.append(calendarIDs)
        return state == .allowed && !calendarIDs.isEmpty ? stored : []
    }
}

actor FakeReminders: ReminderScheduler {
    var allowed = true
    private(set) var current: [PlannedReminder] = []
    private(set) var asked = 0

    func deny() { allowed = false }
    func requestPermission() async -> Bool {
        asked += 1
        return allowed
    }
    func replace(with reminders: [PlannedReminder]) async { current = reminders }
}

struct FakeProvider: ContentProvider {
    let module = ModuleID.reader
    let kinds: Set<ContentKind> = [.note]
    let items: [ContentRef]

    func attachable() async throws -> [ContentRef] { items }
    func current(_ ref: ContentRef) async throws -> ContentRef? { items.first { $0.id == ref.id } }
}

enum Dates {
    static func calendar(_ zone: String = "America/Denver") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, zone: String = "America/Denver") -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func event(
        _ start: Date, hours: Double = 1, title: String = "Standup", zone: String = "America/Denver", rule: RepeatRule? = nil
    ) -> CalendarEvent {
        CalendarEvent(title: title, start: start, end: start.addingTimeInterval(hours * 3_600), timeZoneID: zone, repeatRule: rule)
    }

    static func allDay(_ year: Int, _ month: Int, _ day: Int, through last: Int? = nil, rule: RepeatRule? = nil) -> CalendarEvent {
        CalendarEvent(
            title: "Trip", start: date(year, month, day, zone: "GMT"), end: date(year, month, last ?? day, zone: "GMT"),
            isAllDay: true, timeZoneID: CalendarEvent.allDayZone, repeatRule: rule
        )
    }
}

@Suite struct RepeatTests {
    private let display = Dates.calendar()

    private func days(_ event: CalendarEvent, _ first: CalendarDay, _ last: CalendarDay) -> [Int] {
        event.occurrences(from: first, through: last, in: display).map { display.component(.day, from: $0.start) }
    }

    private func october(_ first: Int = 1, _ last: Int = 31) -> (CalendarDay, CalendarDay) {
        (CalendarDay(year: 2026, month: 10, day: first), CalendarDay(year: 2026, month: 10, day: last))
    }

    @Test func aSingleEventShowsOnceInsideItsRange() {
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        let (first, last) = october()
        #expect(event.occurrences(from: first, through: last, in: display).count == 1)
        #expect(event.occurrences(from: CalendarDay(year: 2026, month: 11, day: 1), through: CalendarDay(year: 2026, month: 11, day: 30), in: display).isEmpty)
    }

    @Test func dailyAndWeeklyLandOnTheRightDays() {
        let (first, last) = october(1, 21)
        #expect(days(Dates.event(Dates.date(2026, 10, 18, 9), rule: .init(frequency: .daily)), first, last) == [18, 19, 20, 21])
        #expect(days(Dates.event(Dates.date(2026, 10, 1, 9), rule: .init(frequency: .weekly)), first, last) == [1, 8, 15])
    }

    @Test("The 31st skips short months, like Apple and Google do")
    func monthlyOnThe31stSkipsShortMonths() {
        let event = Dates.event(Dates.date(2026, 1, 31, 9), rule: .init(frequency: .monthly))
        let found = event.occurrences(from: CalendarDay(year: 2026, month: 1, day: 1), through: CalendarDay(year: 2026, month: 6, day: 30), in: display)
        #expect(found.map { display.component(.month, from: $0.start) } == [1, 3, 5])
        #expect(found.allSatisfy { display.component(.day, from: $0.start) == 31 })
    }

    @Test("February 29 only happens in leap years")
    func yearlyLeapDay() {
        let event = Dates.event(Dates.date(2024, 2, 29, 9), rule: .init(frequency: .yearly))
        let found = event.occurrences(from: CalendarDay(year: 2024, month: 1, day: 1), through: CalendarDay(year: 2032, month: 12, day: 31), in: display)
        #expect(found.map { display.component(.year, from: $0.start) } == [2024, 2028, 2032])
    }

    @Test("A weekly 9 AM stays 9 AM across a daylight-saving change")
    func keepsWallClockAcrossDST() {
        let event = Dates.event(Dates.date(2026, 3, 1, 9), rule: .init(frequency: .weekly))
        let found = event.occurrences(from: CalendarDay(year: 2026, month: 3, day: 1), through: CalendarDay(year: 2026, month: 3, day: 22), in: display)
        #expect(found.count == 4)
        #expect(found.allSatisfy { display.component(.hour, from: $0.start) == 9 })
    }

    @Test("A repeat follows its own zone, so it stays 3 PM at home while you travel")
    func repeatsInTheEventsOwnZone() {
        let event = Dates.event(Dates.date(2026, 3, 1, 15), rule: .init(frequency: .weekly))
        let tokyo = Dates.calendar("Asia/Tokyo")
        let found = event.occurrences(from: CalendarDay(year: 2026, month: 3, day: 2), through: CalendarDay(year: 2026, month: 3, day: 20), in: tokyo)
        #expect(found.allSatisfy { display.component(.hour, from: $0.start) == 15 })
    }

    @Test func untilIsTheLastDayItCanHappen() {
        let event = Dates.event(Dates.date(2026, 10, 1, 9), rule: .init(frequency: .daily, until: CalendarDay(year: 2026, month: 10, day: 3)))
        let (first, last) = october()
        #expect(days(event, first, last) == [1, 2, 3])
    }

    @Test func skippedOccurrencesStayGone() {
        var event = Dates.event(Dates.date(2026, 10, 1, 9), rule: .init(frequency: .daily))
        event.skipped = [Dates.date(2026, 10, 2, 9)]
        let (first, last) = october(1, 3)
        #expect(days(event, first, last) == [1, 3])
    }

    @Test("An old daily event doesn't walk every day since it began")
    func farFutureDoesNotScan() {
        let event = Dates.event(Dates.date(1990, 1, 1, 9), rule: .init(frequency: .daily))
        let (first, last) = october()
        #expect(days(event, first, last).count == 31)
    }

    @Test("A repeat that started before the range and is still going counts")
    func multiDayRepeatOverlappingTheRangeStart() {
        let event = Dates.event(Dates.date(2026, 9, 30, 22), hours: 6, rule: .init(frequency: .monthly))
        let found = event.occurrences(from: CalendarDay(year: 2026, month: 10, day: 1), through: CalendarDay(year: 2026, month: 10, day: 1), in: display)
        #expect(found.count == 1)
    }

    @Test("An absurd date can't crash the calendar", arguments: [1e300, -1e300, Double.greatestFiniteMagnitude])
    func absurdDatesDoNotCrash(seconds: Double) {
        let event = Dates.event(Date(timeIntervalSinceReferenceDate: seconds), rule: .init(frequency: .daily))
        let (first, last) = october()
        #expect(event.occurrences(from: first, through: last, in: display).count <= 31)
    }

    @Test("An all-day event is the same date wherever you are")
    func allDayIgnoresZones() {
        let event = Dates.allDay(2026, 10, 30)
        for zone in ["Pacific/Honolulu", "America/Denver", "Asia/Tokyo", "Pacific/Auckland"] {
            let local = Dates.calendar(zone)
            let day = CalendarDay(year: 2026, month: 10, day: 30)
            let found = event.occurrences(from: day, through: day, in: local)
            #expect(found.count == 1, "\(zone)")
            #expect(found.first.map { CalendarEntry(source: .own($0)).days(in: local) } == [day], "\(zone)")
            #expect(event.occurrences(from: day.adding(days: 1, in: local), through: day.adding(days: 1, in: local), in: local).isEmpty, "\(zone)")
        }
    }

    @Test func multiDayAllDayCoversEveryDay() throws {
        let event = Dates.allDay(2026, 10, 28, through: 30)
        let (first, last) = october()
        let only = try #require(event.occurrences(from: first, through: last, in: display).first)
        #expect(CalendarEntry(source: .own(only)).days(in: display).map(\.day) == [28, 29, 30])
    }

    @Test("A timed event ending at midnight doesn't spill into the next day")
    func midnightEndStaysOnItsDay() throws {
        let event = Dates.event(Dates.date(2026, 10, 15, 22), hours: 2)
        let (first, last) = october()
        let only = try #require(event.occurrences(from: first, through: last, in: display).first)
        #expect(CalendarEntry(source: .own(only)).days(in: display).map(\.day) == [15])
    }

    @Test func aZeroLengthEventStillShows() {
        let event = Dates.event(Dates.date(2026, 10, 15, 0), hours: 0)
        let day = CalendarDay(year: 2026, month: 10, day: 15)
        #expect(event.occurrences(from: day, through: day, in: display).count == 1)
    }
}

@Suite struct MonthGridTests {
    @Test("October 2026 starts on a Thursday, in a week that starts on Sunday")
    func placesTheFirstDay() {
        var calendar = Dates.calendar()
        calendar.firstWeekday = 1
        let grid = CalendarDay(year: 2026, month: 10, day: 1).monthGrid(in: calendar)
        #expect(grid.prefix(4).allSatisfy { $0 == nil })
        #expect(grid[4] == CalendarDay(year: 2026, month: 10, day: 1))
        #expect(grid.count % 7 == 0)
        #expect(grid.compactMap { $0 }.count == 31)
    }

    @Test func respectsAWeekThatStartsOnMonday() {
        var calendar = Dates.calendar()
        calendar.firstWeekday = 2
        let grid = CalendarDay(year: 2026, month: 10, day: 1).monthGrid(in: calendar)
        #expect(grid[3] == CalendarDay(year: 2026, month: 10, day: 1))
    }

    @Test func knowsLeapFebruary() {
        #expect(CalendarDay(year: 2028, month: 2, day: 1).monthGrid(in: Dates.calendar()).compactMap { $0 }.count == 29)
    }

    @Test func movesAcrossYears() {
        let december = CalendarDay(year: 2026, month: 12, day: 15)
        #expect(december.adding(months: 1, in: Dates.calendar()) == CalendarDay(year: 2027, month: 1, day: 1))
    }
}

@Suite struct CalendarVaultTests {
    private func vault(_ blobs: MemoryBlobs = MemoryBlobs()) throws -> CalendarVault {
        CalendarVault(store: blobs, rootKey: try ContentRootKey.generate())
    }

    @Test func savesAndReadsBack() async throws {
        let vault = try vault()
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        try await vault.save(event)
        #expect(try await vault.list().events == [event])
    }

    @Test("Nothing about an event can be read at rest, and its file name holds only the ID")
    func storesOnlyCiphertext() async throws {
        let blobs = MemoryBlobs()
        let vault = try vault(blobs)
        var event = Dates.event(Dates.date(2026, 10, 15, 9), title: "Oncology appointment")
        event.location = "Riverside Clinic"
        event.notes = "Bring the referral letter"
        event.timeZoneID = "America/Denver"
        try await vault.save(event)
        let stored = String(decoding: blobs.everything, as: UTF8.self)
        for secret in ["Oncology", "Riverside", "referral", "America/Denver", "2026"] {
            #expect(!stored.contains(secret))
        }
        #expect(try blobs.names() == ["\(event.id.uuidString.lowercased()).event"])
    }

    @Test("A damaged event is counted, not hidden, and the others still open")
    func damagedEventsAreCounted() async throws {
        let blobs = MemoryBlobs()
        let vault = try vault(blobs)
        let good = Dates.event(Dates.date(2026, 10, 15, 9))
        let bad = Dates.event(Dates.date(2026, 10, 16, 9))
        try await vault.save(good)
        try await vault.save(bad)
        blobs.corrupt("\(bad.id.uuidString.lowercased()).event")
        let listing = try await vault.list()
        #expect(listing.events == [good])
        #expect(listing.unreadable == 1)
    }

    @Test("A sealed event can't be moved onto another event's name")
    func eventsAreBoundToTheirIDs() async throws {
        let blobs = MemoryBlobs()
        let vault = try vault(blobs)
        let first = Dates.event(Dates.date(2026, 10, 15, 9))
        let second = Dates.event(Dates.date(2026, 10, 16, 9))
        try await vault.save(first)
        try await vault.save(second)
        let name = "\(second.id.uuidString.lowercased()).event"
        try blobs.write(try #require(try blobs.read("\(first.id.uuidString.lowercased()).event")), as: name)
        #expect(try await vault.list().unreadable == 1)
    }

    @Test("Another module's blob can't open as an event, even under the same ID")
    func modulesDoNotShareKeys() async throws {
        let blobs = MemoryBlobs()
        let rootKey = try ContentRootKey.generate()
        let vault = CalendarVault(store: blobs, rootKey: rootKey)
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        let body = try JSONEncoder().encode(event)
        let sealed = try ContentCipher.seal(body, key: rootKey.objectKey(for: event.id, purpose: .content), objectID: event.id)
        try blobs.write(sealed, as: "\(event.id.uuidString.lowercased()).event")
        #expect(try await vault.list().unreadable == 1)
    }

    @Test("An event sealed under one ID but claiming another is refused")
    func theIDInsideMustMatch() async throws {
        let blobs = MemoryBlobs()
        let rootKey = try ContentRootKey.generate()
        let vault = CalendarVault(store: blobs, rootKey: rootKey)
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        let other = UUID()
        let sealed = try ContentCipher.seal(JSONEncoder().encode(event), key: rootKey.objectKey(for: other, purpose: .event), objectID: other)
        try blobs.write(sealed, as: "\(other.uuidString.lowercased()).event")
        #expect(try await vault.list().unreadable == 1)
    }

    @Test("A stray file name is counted, and the rest of the list still opens")
    func strayNamesDoNotBreakTheList() async throws {
        let blobs = MemoryBlobs()
        let vault = try vault(blobs)
        try await vault.save(Dates.event(Dates.date(2026, 10, 15, 9)))
        try blobs.write(Data([1]), as: "\(UUID().uuidString.uppercased()).event")
        let listing = try await vault.list()
        #expect(listing.events.count == 1)
        #expect(listing.unreadable == 1)
    }

    @Test func deletesForGood() async throws {
        let blobs = MemoryBlobs()
        let vault = try vault(blobs)
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        try await vault.save(event)
        try await vault.delete(event.id)
        #expect(try blobs.names().isEmpty)
    }
}

@Suite struct SharedKeyTests {
    @Test("A missing key is refused when any module has sealed data, not just the first one checked")
    func everyModuleCounts() throws {
        let reader = MemoryBlobs()
        let calendar = MemoryBlobs()
        try calendar.write(Data([1]), as: "abc.event")
        #expect(throws: KeyStoreError.keyMissing) {
            try ContentRootKey.loadOrCreate(in: MemoryKeys(), sealedIn: [reader, calendar])
        }
    }

    @Test func aFreshDeviceGetsAKey() throws {
        let keys = MemoryKeys()
        let first = try ContentRootKey.loadOrCreate(in: keys, sealedIn: [MemoryBlobs(), MemoryBlobs()])
        let second = try ContentRootKey.loadOrCreate(in: keys, sealedIn: [MemoryBlobs()])
        let id = UUID()
        let sealed = try ContentCipher.seal(Data("same key".utf8), key: first.objectKey(for: id, purpose: .content), objectID: id)
        #expect(try ContentCipher.open(sealed, key: second.objectKey(for: id, purpose: .content), objectID: id) == Data("same key".utf8))
    }
}

@Suite struct ReminderPlanTests {
    private let display = Dates.calendar()
    private let now = Dates.date(2026, 10, 15, 8)

    @Test func firesTheChosenTimeBefore() throws {
        var event = Dates.event(Dates.date(2026, 10, 15, 9))
        event.reminderMinutes = 15
        let plan = ReminderPlanner.plan(for: [event], now: now, display: display)
        #expect(plan.map(\.fireDate) == [Dates.date(2026, 10, 15, 8, 45)])
    }

    @Test("Only the title and time reach the operating system")
    func locationAndNotesStayOut() throws {
        var event = Dates.event(Dates.date(2026, 10, 15, 9), title: "Checkup")
        event.reminderMinutes = 15
        event.location = "Riverside Clinic"
        event.notes = "Bring the referral letter"
        let only = try #require(ReminderPlanner.plan(for: [event], now: now, display: display).first)
        #expect(only.title == "Checkup")
        #expect(!only.body.contains("Riverside"))
        #expect(!only.body.contains("referral"))
        #expect(!only.id.contains("Checkup"))
    }

    @Test func noReminderAndPastRemindersAreLeftOut() {
        var past = Dates.event(Dates.date(2026, 10, 15, 8, 5))
        past.reminderMinutes = 30
        let plain = Dates.event(Dates.date(2026, 10, 16, 9))
        #expect(ReminderPlanner.plan(for: [past, plain], now: now, display: display).isEmpty)
    }

    @Test func allDayCountsBackFromTheMorning() {
        var event = Dates.allDay(2026, 10, 20)
        event.reminderMinutes = 1_440
        let plan = ReminderPlanner.plan(for: [event], now: now, display: display)
        #expect(plan.map(\.fireDate) == [Dates.date(2026, 10, 19, 9)])
    }

    @Test("It stays under the system's limit and keeps the soonest")
    func staysUnderTheLimit() {
        var event = Dates.event(Dates.date(2026, 10, 15, 9), rule: .init(frequency: .daily))
        event.reminderMinutes = 0
        var other = Dates.event(Dates.date(2026, 10, 15, 10), rule: .init(frequency: .daily))
        other.reminderMinutes = 0
        var third = Dates.event(Dates.date(2026, 10, 15, 11), rule: .init(frequency: .daily))
        third.reminderMinutes = 0
        let plan = ReminderPlanner.plan(for: [event, other, third], now: now, display: display)
        #expect(plan.count == ReminderPlanner.limit)
        #expect(plan.map(\.fireDate) == plan.map(\.fireDate).sorted())
        #expect(plan.first?.fireDate == Dates.date(2026, 10, 15, 9))
    }

    @Test func skippedOccurrencesDoNotRemind() {
        var event = Dates.event(Dates.date(2026, 10, 15, 9), rule: .init(frequency: .daily, until: CalendarDay(year: 2026, month: 10, day: 15)))
        event.reminderMinutes = 0
        event.skipped = [Dates.date(2026, 10, 15, 9)]
        #expect(ReminderPlanner.plan(for: [event], now: now, display: display).isEmpty)
    }
}

@MainActor
@Suite struct CalendarModelTests {
    private let devices = FakeDevices()
    private let reminders = FakeReminders()
    private let blobs = MemoryBlobs()

    private func model(mode: CalendarModel.Mode = .agenda, registry: ModuleRegistry? = nil) throws -> CalendarModel {
        let suite = "totality.tests.\(UUID().uuidString)"
        return CalendarModel(
            vault: CalendarVault(store: blobs, rootKey: try ContentRootKey.generate()), devices: devices, reminders: reminders,
            registry: registry, startingMode: mode, display: Dates.calendar(),
            defaults: UserDefaults(suiteName: suite)!, now: { Dates.date(2026, 10, 15, 8, 30) }
        )
    }

    private func draft(_ title: String = "Dentist", day: Int = 15, hour: Int = 9) -> EventDraft {
        var draft = EventDraft(start: Dates.date(2026, 10, day, hour), end: Dates.date(2026, 10, day, hour + 1))
        draft.title = title
        return draft
    }

    private func onlyOccurrence(_ model: CalendarModel, day: Int) throws -> EventOccurrence {
        let entry = try #require(model.entries(on: CalendarDay(year: 2026, month: 10, day: day)).first)
        guard case .own(let occurrence) = entry.source else {
            Issue.record("Not an own event")
            throw CalendarError.notFound
        }
        return occurrence
    }

    @Test func createsAnEventThatShowsInTheAgenda() async throws {
        let model = try model()
        #expect(await model.create(draft()))
        #expect(model.agenda.map(\.day) == [CalendarDay(year: 2026, month: 10, day: 15)])
        #expect(model.agenda.first?.entries.first?.title == "Dentist")
        #expect(try blobs.names().count == 1)
    }

    @Test func theAgendaLeavesOutThePast() async throws {
        let model = try model()
        _ = await model.create(draft(day: 14))
        #expect(model.agenda.isEmpty)
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 14)).count == 1)
    }

    @Test func refusesAnEndBeforeTheStart() async throws {
        let model = try model()
        var bad = draft()
        bad.end = bad.start.addingTimeInterval(-60)
        #expect(await model.create(bad) == false)
        #expect(model.notice != nil)
        #expect(try blobs.names().isEmpty)
    }

    @Test func refusesARepeatThatEndsBeforeItStarts() async throws {
        let model = try model()
        var bad = draft()
        bad.frequency = .daily
        bad.until = Dates.date(2026, 10, 1)
        #expect(await model.create(bad) == false)
    }

    @Test("An all-day event stores plain dates")
    func allDayIsStoredAsDates() async throws {
        let model = try model()
        var allDay = draft()
        allDay.isAllDay = true
        allDay.end = allDay.start
        _ = await model.create(allDay)
        let event = try #require(model.events.first)
        #expect(event.timeZoneID == CalendarEvent.allDayZone)
        #expect(event.start == Dates.date(2026, 10, 15, zone: "GMT"))
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 15)).first?.isAllDay == true)
    }

    @Test("Editing one repeat leaves the rest alone and keeps the edit")
    func editingOneOccurrence() async throws {
        let model = try model()
        var series = draft("Standup")
        series.frequency = .daily
        _ = await model.create(series)
        let second = try onlyOccurrence(model, day: 16)
        var edit = model.draft(for: second)
        edit.title = "Standup with Sam"
        #expect(await model.update(second, with: edit, scope: .thisOccurrence))
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 15)).map(\.title) == ["Standup"])
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 16)).map(\.title) == ["Standup with Sam"])
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 17)).map(\.title) == ["Standup"])
    }

    @Test("Editing all repeats from a later one moves the series, not to that date")
    func editingAllFromALaterOccurrence() async throws {
        let model = try model()
        var series = draft("Standup")
        series.frequency = .daily
        _ = await model.create(series)
        let later = try onlyOccurrence(model, day: 20)
        var edit = model.draft(for: later)
        edit.start = Dates.date(2026, 10, 20, 10)
        edit.end = Dates.date(2026, 10, 20, 11)
        edit.title = "Team standup"
        #expect(await model.update(later, with: edit, scope: .allOccurrences))
        let first = try onlyOccurrence(model, day: 15)
        #expect(first.start == Dates.date(2026, 10, 15, 10))
        #expect(first.event.title == "Team standup")
        #expect(model.events.count == 1)
    }

    @Test func movingASeriesKeepsItsSkippedDaysSkipped() async throws {
        let model = try model()
        var series = draft("Standup")
        series.frequency = .daily
        _ = await model.create(series)
        await model.delete(try onlyOccurrence(model, day: 17), scope: .thisOccurrence)
        let first = try onlyOccurrence(model, day: 15)
        var edit = model.draft(for: first)
        edit.start = Dates.date(2026, 10, 15, 11)
        edit.end = Dates.date(2026, 10, 15, 12)
        _ = await model.update(first, with: edit, scope: .allOccurrences)
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 17)).isEmpty)
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 18)).count == 1)
    }

    @Test func deletingOneRepeatKeepsTheOthers() async throws {
        let model = try model()
        var series = draft("Standup")
        series.frequency = .daily
        _ = await model.create(series)
        await model.delete(try onlyOccurrence(model, day: 16), scope: .thisOccurrence)
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 16)).isEmpty)
        #expect(model.entries(on: CalendarDay(year: 2026, month: 10, day: 17)).count == 1)
    }

    @Test func deletingAllRemovesTheEvent() async throws {
        let model = try model()
        var series = draft("Standup")
        series.frequency = .daily
        _ = await model.create(series)
        await model.delete(try onlyOccurrence(model, day: 16), scope: .allOccurrences)
        #expect(model.agenda.isEmpty)
        #expect(try blobs.names().isEmpty)
    }

    @Test("Device calendars stay away until permission is given")
    func deviceCalendarsNeedPermission() async throws {
        devices.available = [DeviceCalendar(id: "work", title: "Work", account: "Google")]
        devices.stored = [DeviceEvent(id: "1", title: "Budget review", location: "", notes: "", start: Dates.date(2026, 10, 15, 13), end: Dates.date(2026, 10, 15, 14), isAllDay: false, calendarTitle: "Work")]
        let model = try model()
        await model.load()
        #expect(model.deviceAccess == .notAsked)
        #expect(model.agenda.isEmpty)
        await model.allowDeviceCalendars()
        #expect(model.deviceAccess == .allowed)
        #expect(model.agenda.first?.entries.map(\.title) == ["Budget review"])
    }

    @Test("Device events are never written into Totality's storage")
    func deviceEventsAreNotStored() async throws {
        devices.state = .allowed
        devices.available = [DeviceCalendar(id: "work", title: "Work", account: "Google")]
        devices.stored = [DeviceEvent(id: "1", title: "Budget review", location: "", notes: "", start: Dates.date(2026, 10, 15, 13), end: Dates.date(2026, 10, 15, 14), isAllDay: false, calendarTitle: "Work")]
        let model = try model()
        await model.load()
        #expect(model.agenda.count == 1)
        #expect(model.events.isEmpty)
        #expect(try blobs.names().isEmpty)
    }

    @Test func aRefusalSaysSoAndShowsNothing() async throws {
        devices.grants = false
        let model = try model()
        await model.allowDeviceCalendars()
        #expect(model.deviceAccess == .denied)
        #expect(model.notice != nil)
    }

    @Test func hidingACalendarHidesItsEvents() async throws {
        devices.state = .allowed
        let work = DeviceCalendar(id: "work", title: "Work", account: "Google")
        devices.available = [work]
        devices.stored = [DeviceEvent(id: "1", title: "Budget review", location: "", notes: "", start: Dates.date(2026, 10, 15, 13), end: Dates.date(2026, 10, 15, 14), isAllDay: false, calendarTitle: "Work")]
        let model = try model()
        await model.load()
        model.setVisible(false, calendar: work)
        #expect(model.agenda.isEmpty)
        model.setVisible(true, calendar: work)
        #expect(model.agenda.count == 1)
    }

    @Test func remindersFollowSavesAndDeletes() async throws {
        let model = try model()
        var withReminder = draft()
        withReminder.reminderMinutes = 10
        _ = await model.create(withReminder)
        #expect(await reminders.asked == 1)
        #expect(await reminders.current.count == 1)
        await model.delete(try onlyOccurrence(model, day: 15), scope: .allOccurrences)
        #expect(await reminders.current.isEmpty)
    }

    @Test("An event with no reminder never asks for notification permission")
    func noReminderNoPrompt() async throws {
        let model = try model()
        _ = await model.create(draft())
        #expect(await reminders.asked == 0)
    }

    @Test("Refused notifications keep the event and say the reminder won't show")
    func refusedNotifications() async throws {
        await reminders.deny()
        let model = try model()
        var withReminder = draft()
        withReminder.reminderMinutes = 10
        #expect(await model.create(withReminder))
        #expect(model.events.count == 1)
        #expect(model.notice != nil)
    }

    @Test("Attachments cross only as refs, and a deleted item says it's gone")
    func attachments() async throws {
        let id = UUID()
        let note = ContentRef(module: .reader, kind: .note, id: id, keyRef: .crk(objectID: id), preview: .init(title: "Lease"))
        let registry = try ModuleRegistry(handlers: [FakeProvider(items: [note]), CalendarModule()])
        let model = try model(registry: registry)
        #expect(await model.attachableContent() == [note])
        #expect(await model.current(note) == note)
        var attached = draft()
        attached.attachments = [note]
        _ = await model.create(attached)
        #expect(model.events.first?.attachments == [note])

        let empty = try ModuleRegistry(handlers: [FakeProvider(items: [])])
        let afterDelete = try self.model(registry: empty)
        #expect(await afterDelete.current(note) == nil)
    }

    @Test("Calendar never offers its own events as attachments")
    func providersExcludeTheAsker() throws {
        let registry = try ModuleRegistry(handlers: [FakeProvider(items: [])])
        #expect(registry.providers(for: .reader).isEmpty)
        #expect(registry.providers(for: .calendar).count == 1)
    }

    @Test func monthsMoveAndComeBack() throws {
        let model = try model(mode: .month)
        model.show(monthsFromNow: 3)
        #expect(model.month == CalendarDay(year: 2027, month: 1, day: 1))
        model.showToday()
        #expect(model.month == CalendarDay(year: 2026, month: 10, day: 1))
        #expect(model.selectedDay == CalendarDay(year: 2026, month: 10, day: 15))
    }

    @Test("A distant month still shows its repeats")
    func distantMonthsFillIn() async throws {
        let model = try model(mode: .month)
        var series = draft("Rent")
        series.frequency = .monthly
        _ = await model.create(series)
        model.show(monthsFromNow: 14)
        #expect(model.entries(on: CalendarDay(year: 2027, month: 12, day: 15)).map(\.title) == ["Rent"])
    }

    @Test("A new event on today starts at the next hour, and on another day in the morning")
    func newEventTimes() throws {
        let model = try model(mode: .month)
        #expect(model.newDraft().start == Dates.date(2026, 10, 15, 9))
        model.selectedDay = CalendarDay(year: 2026, month: 10, day: 20)
        #expect(model.newDraft().start == Dates.date(2026, 10, 20, 9))
    }

    @Test("In the agenda a new event starts today, whatever day the month view had selected")
    func agendaIgnoresTheMonthSelection() throws {
        let model = try model(mode: .agenda)
        model.selectedDay = CalendarDay(year: 2026, month: 10, day: 20)
        #expect(model.newDraft().start == Dates.date(2026, 10, 15, 9))
    }

    @Test func aDraftFromAnAllDayEventKeepsItsDates() async throws {
        let model = try model()
        var allDay = draft()
        allDay.isAllDay = true
        allDay.end = allDay.start
        _ = await model.create(allDay)
        let again = model.draft(for: try onlyOccurrence(model, day: 15))
        #expect(CalendarDay(again.start, in: model.display) == CalendarDay(year: 2026, month: 10, day: 15))
    }

    @Test func registersForEvents() throws {
        let id = UUID()
        let ref = ContentRef(module: .calendar, kind: .event, id: id, keyRef: .crk(objectID: id), preview: .init(title: "Dentist"))
        #expect(try ModuleRegistry(handlers: [CalendarModule()]).handler(for: ref)?.module == .calendar)
    }
}
