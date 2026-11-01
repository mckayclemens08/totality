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

    @Test("A closed vault refuses writes, so nothing lands under an old key")
    func closedVaultRefusesWrites() async throws {
        let blobs = MemoryBlobs()
        let vault = try vault(blobs)
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        try await vault.save(event)
        await vault.close()
        await #expect(throws: CalendarError.closed) { try await vault.save(Dates.event(Dates.date(2026, 10, 16, 9))) }
        await #expect(throws: CalendarError.closed) { try await vault.delete(event.id) }
        #expect(try blobs.names().count == 1)
    }

    @Test func deletesForGood() async throws {
        let blobs = MemoryBlobs()
        let vault = try vault(blobs)
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        try await vault.save(event)
        try await vault.delete(event.id)
        #expect(try blobs.names().allSatisfy { $0.hasSuffix(".deleted") })
    }
}

@Suite struct CalendarSyncTests {
    private func pair() throws -> (first: CalendarVault, second: CalendarVault) {
        let key = try ContentRootKey.generate()
        return (CalendarVault(store: MemoryBlobs(), rootKey: key), CalendarVault(store: MemoryBlobs(), rootKey: key))
    }

    @Test func anEventMovesBetweenDevices() async throws {
        let (first, second) = try pair()
        let event = Dates.event(Dates.date(2026, 10, 15, 9), title: "Dentist")
        try await first.save(event)
        try await second.store(try #require(try await first.sealedObject(event.id)), ifLocalHash: nil)
        #expect(try await second.event(event.id) == event)
    }

    @Test("An event sealed under another key is refused")
    func refusesOtherKeys() async throws {
        let (first, _) = try pair()
        let stranger = CalendarVault(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        try await stranger.save(event)
        await #expect(throws: (any Error).self) { try await first.store(try #require(try await stranger.sealedObject(event.id)), ifLocalHash: nil) }
    }

    @Test("Both changed: the newest stays, and the older is kept as a copy")
    func conflictKeepsBoth() async throws {
        let (first, second) = try pair()
        var event = Dates.event(Dates.date(2026, 10, 15, 9), title: "Dentist")
        event.updatedAt = Date(timeIntervalSince1970: 100)
        try await first.save(event)
        var newer = event
        newer.title = "Dentist moved"
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        try await second.save(newer)
        let local = try #require(try await first.sealedObject(event.id))
        let remote = try #require(try await second.sealedObject(event.id))
        #expect(try await first.resolveConflict(local: local, remote: remote) == .keepRemote)
        #expect(try await first.list().events.contains { $0.title == "Dentist (conflict copy)" })
    }

    @Test("A store only lands if nothing changed since sync looked")
    func storeChecksTheVersion() async throws {
        let (first, second) = try pair()
        var event = Dates.event(Dates.date(2026, 10, 15, 9), title: "One")
        try await first.save(event)
        try await second.store(try #require(try await first.sealedObject(event.id)), ifLocalHash: nil)
        let looked = try await second.sealedHash(of: event.id)
        event.title = "Typed just now"
        try await second.save(event)
        await #expect(throws: SyncError.changedLocally) {
            try await second.store(try #require(try await first.sealedObject(event.id)), ifLocalHash: looked)
        }
        #expect(try await second.event(event.id).title == "Typed just now")
    }

    @Test("Removed by sync goes to the trash, and comes round on the key move list")
    func removalsAreKept() async throws {
        let blobs = MemoryBlobs()
        let vault = CalendarVault(store: blobs, rootKey: try ContentRootKey.generate())
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        try await vault.save(event)
        try await vault.removeObject(event.id, ifLocalHash: try #require(try await vault.sealedHash(of: event.id)))
        #expect(try await vault.list().events.isEmpty)
        #expect(try blobs.read("\(event.id.uuidString.lowercased()).event.trash") != nil)
        #expect(CalendarVault.sealedPurposes[".event.trash"] == .event)
    }

    @Test("A retried conflict doesn't make a second copy")
    func conflictCopiesDoNotDouble() async throws {
        let (first, second) = try pair()
        var event = Dates.event(Dates.date(2026, 10, 15, 9), title: "Dentist")
        event.updatedAt = Date(timeIntervalSince1970: 100)
        try await first.save(event)
        var newer = event
        newer.title = "Dentist moved"
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        try await second.save(newer)
        let local = try #require(try await first.sealedObject(event.id))
        let remote = try #require(try await second.sealedObject(event.id))
        for _ in 0..<3 { _ = try await first.resolveConflict(local: local, remote: remote) }
        #expect(try await first.list().events.count == 2)
    }

    @Test("Identical events apart from the time saved make no copy")
    func noCopyForTheSameEvent() async throws {
        let (first, second) = try pair()
        var event = Dates.event(Dates.date(2026, 10, 15, 9))
        event.updatedAt = Date(timeIntervalSince1970: 100)
        try await first.save(event)
        event.updatedAt = Date(timeIntervalSince1970: 200)
        try await second.save(event)
        _ = try await first.resolveConflict(
            local: try #require(try await first.sealedObject(event.id)),
            remote: try #require(try await second.sealedObject(event.id))
        )
        #expect(try await first.list().events.count == 1)
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

@Suite struct TimelineLayoutTests {
    private let calendar = Dates.calendar()
    private let day = CalendarDay(year: 2026, month: 10, day: 15)

    private func entry(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEntry {
        let event = CalendarEvent(
            title: title, location: "", notes: "", start: start, end: end, isAllDay: allDay,
            timeZoneID: calendar.timeZone.identifier, createdAt: start, updatedAt: start
        )
        return CalendarEntry(source: .own(EventOccurrence(event: event, start: start, end: end)))
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Dates.date(2026, 10, 15, hour, minute)
    }

    private func blocks(_ entries: CalendarEntry...) -> [String: TimelineBlock] {
        Dictionary(uniqueKeysWithValues: TimelineLayout.blocks(for: entries, on: day, in: calendar).map { ($0.entry.title, $0) })
    }

    @Test func eventsApartEachGetTheFullWidth() throws {
        let found = blocks(entry("Standup", at(9), at(10)), entry("Lunch", at(12), at(13)))
        #expect(found["Standup"]?.columns == 1)
        #expect(found["Lunch"]?.columns == 1)
        #expect(found["Lunch"]?.startMinute == 720)
    }

    @Test func overlappingEventsSitSideBySide() throws {
        let found = blocks(entry("Standup", at(9), at(10)), entry("Call", at(9, 30), at(10, 30)))
        #expect(found["Standup"]?.columns == 2)
        #expect(found["Call"]?.columns == 2)
        #expect(found["Standup"]?.column != found["Call"]?.column)
    }

    @Test("An event ending as another starts doesn't push it aside")
    func touchingEventsDontOverlap() {
        let found = blocks(entry("Standup", at(9), at(10)), entry("Review", at(10), at(11)))
        #expect(found["Review"]?.columns == 1)
    }

    @Test("A freed column is used again, and everything in the group shares the count")
    func columnsAreReused() {
        let found = blocks(
            entry("Workshop", at(9), at(12)), entry("Call", at(9), at(10)), entry("Review", at(10), at(11))
        )
        #expect(found["Workshop"]?.columns == 2)
        #expect(found["Call"]?.columns == 2)
        #expect(found["Review"]?.column == found["Call"]?.column)
    }

    @Test("A later event starts a new group, with its own width")
    func groupsAreSeparate() {
        let found = blocks(entry("Standup", at(9), at(10)), entry("Call", at(9), at(10)), entry("Lunch", at(12), at(13)))
        #expect(found["Lunch"]?.columns == 1)
        #expect(found["Lunch"]?.column == 0)
    }

    @Test("All-day events have their own row, not a place on the hours")
    func allDayEventsAreLeftOut() {
        #expect(blocks(entry("Holiday", at(0), at(23), allDay: true)).isEmpty)
    }

    @Test func aShortEventStaysTappable() {
        let found = blocks(entry("Quick call", at(9), at(9, 5)))
        #expect(found["Quick call"]?.endMinute == 570)
    }

    @Test("An event from yesterday into tomorrow fills the day")
    func multiDayEventsAreClamped() {
        let found = blocks(entry("Conference", Dates.date(2026, 10, 14, 20), Dates.date(2026, 10, 16, 8)))
        #expect(found["Conference"]?.startMinute == 0)
        #expect(found["Conference"]?.endMinute == 1_440)
    }

    @Test("An event starting late in the day still fits on it")
    func aLateEventStaysOnTheDay() {
        let found = blocks(entry("Night train", at(23, 50), Dates.date(2026, 10, 16, 6)))
        #expect(found["Night train"]?.startMinute == 1_410)
        #expect(found["Night train"]?.endMinute == 1_440)
    }

    @Test("On the day clocks change, 9 AM still lines up with 9 AM")
    func clockChangesKeepTheClockTime() {
        var zone = Calendar(identifier: .gregorian)
        zone.timeZone = TimeZone(identifier: "America/Denver")!
        let changeDay = CalendarDay(year: 2026, month: 11, day: 1)
        let start = zone.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!
        #expect(TimelineLayout.minute(of: start, on: changeDay, in: zone) == 540)
    }
}

@MainActor
@Suite struct CalendarModelTests {
    private let devices = FakeDevices()
    private let reminders = FakeReminders()
    private let blobs = MemoryBlobs()

    private func model(
        mode: CalendarModel.Mode = .schedule, registry: ModuleRegistry? = nil, weekSpan: Int = 3,
        display: Calendar = Dates.calendar(), defaults: UserDefaults? = nil
    ) throws -> CalendarModel {
        let suite = "totality.tests.\(UUID().uuidString)"
        return CalendarModel(
            vault: CalendarVault(store: blobs, rootKey: try ContentRootKey.generate()), devices: devices, reminders: reminders,
            registry: registry, startingMode: mode, display: display, weekSpan: weekSpan,
            defaults: defaults ?? UserDefaults(suiteName: suite)!, now: { Dates.date(2026, 10, 15, 8, 30) }
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

    @Test func createsAnEventThatShowsInTheSchedule() async throws {
        let model = try model()
        #expect(await model.create(draft()))
        #expect(model.schedule.map(\.day) == [CalendarDay(year: 2026, month: 10, day: 15)])
        #expect(model.schedule.first?.entries.first?.title == "Dentist")
        #expect(try blobs.names().count == 1)
    }

    @Test func theScheduleLeavesOutThePast() async throws {
        let model = try model()
        _ = await model.create(draft(day: 14))
        #expect(model.schedule.isEmpty)
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
        #expect(model.schedule.isEmpty)
        #expect(try blobs.names().allSatisfy { $0.hasSuffix(".deleted") })
    }

    @Test("An edit from a stale screen is refused, so it can't undo what a sync just brought in")
    func staleEditsAreRefused() async throws {
        let vault = CalendarVault(store: blobs, rootKey: try ContentRootKey.generate())
        let model = CalendarModel(
            vault: vault, devices: devices, reminders: reminders, startingMode: .schedule, display: Dates.calendar(),
            defaults: UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!, now: { Dates.date(2026, 10, 15, 8, 30) }
        )
        _ = await model.create(draft("Dentist"))
        let stale = try onlyOccurrence(model, day: 15)
        var newer = stale.event
        newer.title = "Dentist moved"
        newer.updatedAt = newer.updatedAt.addingTimeInterval(60)
        try await vault.save(newer)
        var edit = model.draft(for: stale)
        edit.title = "Old screen's change"
        #expect(await model.update(stale, with: edit, scope: .allOccurrences) == false)
        #expect(try await vault.event(newer.id).title == "Dentist moved")
        #expect(model.notice != nil)
    }

    @Test("A stale screen can't delete what a sync just changed")
    func staleDeletesAreRefused() async throws {
        let vault = CalendarVault(store: blobs, rootKey: try ContentRootKey.generate())
        let model = CalendarModel(
            vault: vault, devices: devices, reminders: reminders, startingMode: .schedule, display: Dates.calendar(),
            defaults: UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!, now: { Dates.date(2026, 10, 15, 8, 30) }
        )
        _ = await model.create(draft("Dentist"))
        let stale = try onlyOccurrence(model, day: 15)
        var newer = stale.event
        newer.title = "Dentist moved"
        newer.updatedAt = newer.updatedAt.addingTimeInterval(60)
        try await vault.save(newer)
        await model.delete(stale, scope: .allOccurrences)
        #expect(try await vault.event(newer.id).title == "Dentist moved")
        #expect(model.notice != nil)
    }

    @Test("Saving against an old version is refused in one step")
    func vaultRefusesOldVersions() async throws {
        let vault = CalendarVault(store: blobs, rootKey: try ContentRootKey.generate())
        let event = Dates.event(Dates.date(2026, 10, 15, 9), title: "One")
        try await vault.save(event)
        var newer = event
        newer.updatedAt = event.updatedAt.addingTimeInterval(60)
        try await vault.save(newer)
        await #expect(throws: CalendarError.changed) { try await vault.save([event], ifStillAt: event) }
        await #expect(throws: CalendarError.changed) { try await vault.delete(event.id, ifStillAt: event) }
    }

    @Test("A crash partway through a delete is finished, not undone")
    func interruptedDeletesFinish() async throws {
        let vault = CalendarVault(store: blobs, rootKey: try ContentRootKey.generate())
        let event = Dates.event(Dates.date(2026, 10, 15, 9))
        try await vault.save(event)
        try blobs.write(Data(), as: "\(event.id.uuidString.lowercased()).deleted")
        #expect(try await vault.sealedObjectIDs().isEmpty)
        #expect(try await vault.list().events.isEmpty)
    }

    @Test("Device calendars stay away until permission is given")
    func deviceCalendarsNeedPermission() async throws {
        devices.available = [DeviceCalendar(id: "work", title: "Work", account: "Google")]
        devices.stored = [DeviceEvent(id: "1", title: "Budget review", location: "", notes: "", start: Dates.date(2026, 10, 15, 13), end: Dates.date(2026, 10, 15, 14), isAllDay: false, calendarTitle: "Work")]
        let model = try model()
        await model.load()
        #expect(model.deviceAccess == .notAsked)
        #expect(model.schedule.isEmpty)
        await model.allowDeviceCalendars()
        #expect(model.deviceAccess == .allowed)
        #expect(model.schedule.first?.entries.map(\.title) == ["Budget review"])
    }

    @Test("Device events are never written into Totality's storage")
    func deviceEventsAreNotStored() async throws {
        devices.state = .allowed
        devices.available = [DeviceCalendar(id: "work", title: "Work", account: "Google")]
        devices.stored = [DeviceEvent(id: "1", title: "Budget review", location: "", notes: "", start: Dates.date(2026, 10, 15, 13), end: Dates.date(2026, 10, 15, 14), isAllDay: false, calendarTitle: "Work")]
        let model = try model()
        await model.load()
        #expect(model.schedule.count == 1)
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
        #expect(model.schedule.isEmpty)
        model.setVisible(true, calendar: work)
        #expect(model.schedule.count == 1)
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
        model.select(CalendarDay(year: 2026, month: 10, day: 20))
        #expect(model.newDraft().start == Dates.date(2026, 10, 20, 9))
    }

    @Test("In Schedule a new event starts today, whatever day the month view had selected")
    func scheduleIgnoresTheMonthSelection() throws {
        let model = try model(mode: .schedule)
        model.select(CalendarDay(year: 2026, month: 10, day: 20))
        #expect(model.newDraft().start == Dates.date(2026, 10, 15, 9))
    }

    @Test("A tapped hour on the timeline starts the event there")
    func aTappedHourSetsTheTime() throws {
        let model = try model(mode: .day)
        let draft = model.newDraft(on: CalendarDay(year: 2026, month: 10, day: 20), hour: 14)
        #expect(draft.start == Dates.date(2026, 10, 20, 14))
        #expect(draft.end == Dates.date(2026, 10, 20, 15))
    }

    @Test("Moving goes by the view: a month, a day, or the width of the week")
    func movingFollowsTheView() throws {
        let model = try model(mode: .month)
        model.move(by: 1)
        #expect(model.selectedDay == CalendarDay(year: 2026, month: 11, day: 1))
        model.mode = .day
        model.move(by: 1)
        #expect(model.selectedDay == CalendarDay(year: 2026, month: 11, day: 2))
        model.mode = .week
        model.move(by: -1)
        #expect(model.selectedDay == CalendarDay(year: 2026, month: 10, day: 30))
        #expect(model.month == CalendarDay(year: 2026, month: 10, day: 1))
    }

    @Test("Coming back to this month lands on today, not the 1st")
    func returningToThisMonthPicksToday() throws {
        let model = try model(mode: .month)
        model.move(by: 1)
        model.move(by: -1)
        #expect(model.selectedDay == model.today)
        #expect(model.isShowingToday)
    }

    @Test func scheduleDoesNotMove() throws {
        let model = try model(mode: .schedule)
        model.move(by: 1)
        #expect(!model.canMove)
        #expect(model.selectedDay == model.today)
        #expect(model.isShowingToday)
    }

    @Test("A full week starts where the device's weeks start, and three days start on the selected day")
    func visibleDays() throws {
        let days = { (span: Int) in
            let model = try self.model(mode: .week, weekSpan: span)
            return model.visibleDays
        }
        let threeDays = try days(3)
        #expect(threeDays == (15...17).map { CalendarDay(year: 2026, month: 10, day: $0) })
        // October 15, 2026 is a Thursday, and this calendar's weeks start on Sunday.
        let week = try days(7)
        #expect(week == (11...17).map { CalendarDay(year: 2026, month: 10, day: $0) })
    }

    @Test("A week follows the device when weeks start on Monday")
    func aMondayWeek() throws {
        var display = Dates.calendar()
        display.firstWeekday = 2
        let model = try model(mode: .week, weekSpan: 7, display: display)
        #expect(model.visibleDays == (12...18).map { CalendarDay(year: 2026, month: 10, day: $0) })
    }

    @Test("Today only offers itself once you've left it")
    func todayButton() throws {
        let model = try model(mode: .day)
        #expect(model.isShowingToday)
        model.move(by: 1)
        #expect(!model.isShowingToday)
        model.mode = .week
        #expect(!model.isShowingToday)
        model.move(by: -1)
        model.mode = .week
        #expect(model.isShowingToday)
        model.showToday()
        #expect(model.isShowingToday)
        model.mode = .month
        model.select(CalendarDay(year: 2026, month: 10, day: 20))
        #expect(!model.isShowingToday)
    }

    @Test("Titles say where you are", arguments: [
        (CalendarModel.Mode.month, "October 2026"),
        (.day, "Thursday, Oct 15"),
        (.week, "Oct 15 to 17"),
        (.schedule, "Schedule"),
    ])
    func titles(mode: CalendarModel.Mode, title: String) throws {
        #expect(try model(mode: mode).title == title)
    }

    @Test func aWeekAcrossTwoMonthsNamesBoth() throws {
        let model = try model(mode: .week)
        model.select(CalendarDay(year: 2026, month: 10, day: 30))
        #expect(model.title == "Oct 30 to Nov 1")
    }

    @Test("The first tap picks a day, and the second opens it")
    func tappingTwiceOpensTheDay() throws {
        let model = try model(mode: .month)
        let day = CalendarDay(year: 2026, month: 10, day: 20)
        model.choose(day)
        #expect(model.selectedDay == day)
        #expect(model.mode == .month)
        model.choose(day)
        #expect(model.mode == .day)
    }

    @Test("Opening the Calendar lands on the month and today, wherever it was left")
    func opensOnTheMonth() throws {
        let model = try model(mode: .week)
        model.select(CalendarDay(year: 2026, month: 12, day: 20))
        model.showFront()
        #expect(model.mode == .month)
        #expect(model.selectedDay == model.today)
        #expect(model.month == CalendarDay(year: 2026, month: 10, day: 1))
    }

    @Test("A week at a far date still shows its events, even across a month's edge")
    func aWeekFillsInBeyondTheMonth() async throws {
        let model = try model(mode: .week)
        var series = draft("Rent")
        series.frequency = .monthly
        _ = await model.create(series)
        model.select(CalendarDay(year: 2027, month: 11, day: 30))
        #expect(model.entries(on: CalendarDay(year: 2027, month: 12, day: 15)).map(\.title).isEmpty)
        model.move(by: 5)
        #expect(model.entries(on: CalendarDay(year: 2027, month: 12, day: 15)).map(\.title) == ["Rent"])
    }

    @Test("Moving inside what's built doesn't ask the device again")
    func movingStaysCheap() async throws {
        let model = try model(mode: .day)
        await model.load()
        let asked = devices.askedFor.count
        model.move(by: 1)
        #expect(devices.askedFor.count == asked)
        model.move(by: 200)
        #expect(devices.askedFor.count == asked + 1)
    }

    @Test("Next is the event on now or the soonest after it, never an all-day one")
    func nextEvent() async throws {
        let model = try model()
        var allDay = draft("Holiday")
        allDay.isAllDay = true
        allDay.end = Dates.date(2026, 10, 17, 10)
        _ = await model.create(allDay)
        _ = await model.create(draft("Standup", hour: 8))
        _ = await model.create(draft("Dentist", hour: 11))
        #expect(model.nextEntry?.title == "Standup")
        let done = try self.model()
        _ = await done.create(draft("Standup", hour: 7))
        _ = await done.create(draft("Dentist", hour: 11))
        #expect(done.nextEntry?.title == "Dentist")
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
