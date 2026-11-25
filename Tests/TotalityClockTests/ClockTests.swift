import Foundation
import Testing
import TotalityCore
@testable import TotalityClock

final class MemoryBlobs: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    func exists(_ name: String) throws -> Bool { lock.withLock { blobs[name] != nil } }
    var everything: Data { lock.withLock { blobs.values.reduce(Data(), +) } }
}

/// What a test set with "iOS": nothing rings.
final class FakeAlarms: AlarmScheduling, @unchecked Sendable {
    let ringsAsAlarm: Bool
    var state: AlarmAccess
    var refuse: Set<UUID> = []
    private(set) var alarms: [UUID: ClockAlarm] = [:]
    private(set) var timers: [UUID: RunningTimer] = [:]
    private(set) var bedtime: SleepSchedule?

    init(ringsAsAlarm: Bool = true, state: AlarmAccess = .allowed) {
        self.ringsAsAlarm = ringsAsAlarm
        self.state = state
    }

    func access() async -> AlarmAccess { state }
    func requestAccess() async -> AlarmAccess {
        if state == .notAsked { state = .allowed }
        return state
    }
    func schedule(_ alarm: ClockAlarm, sound: String?) async throws {
        alarms[alarm.id] = nil
        guard alarm.isOn else { return }
        guard state == .allowed, !refuse.contains(alarm.id) else { throw AlarmSchedulingError.failed }
        alarms[alarm.id] = alarm
    }
    func cancelAlarm(_ id: UUID) async { alarms[id] = nil }
    func start(_ timer: RunningTimer, sound: String?, at now: Date) async throws {
        guard state == .allowed else { throw AlarmSchedulingError.notAllowed }
        timers[timer.id] = timer
    }
    func pause(_ timer: RunningTimer) async { timers[timer.id] = nil }
    func cancelTimer(_ id: UUID) async { timers[id] = nil }
    func bedtimeReminder(_ sleep: SleepSchedule?) async { bedtime = sleep }
}

/// A moving clock for tests.
final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = 1
    return calendar
}

let denver = calendar("America/Denver")

func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar = denver) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Friday 20 November 2026, 2:35 pm in Denver.
let friday = moment(2026, 11, 20, 14, 35)

@Suite struct ClockMathTests {
    @Test("A repeating alarm rings on its next weekday, a once alarm at its next time")
    func nextFire() {
        let saturdays = ClockAlarm(hour: 7, minute: 30, weekdays: [7])
        #expect(ClockMath.nextFire(of: saturdays, after: friday, in: denver) == moment(2026, 11, 21, 7, 30))
        let once = ClockAlarm(hour: 6, minute: 0)
        #expect(ClockMath.nextFire(of: once, after: friday, in: denver) == moment(2026, 11, 21, 6, 0))
        let later = ClockAlarm(hour: 15, minute: 0)
        #expect(ClockMath.nextFire(of: later, after: friday, in: denver) == moment(2026, 11, 20, 15, 0))
        var off = later
        off.isOn = false
        #expect(ClockMath.nextFire(of: off, after: friday, in: denver) == nil)
        let past = ClockAlarm(hour: 5, minute: 45, date: moment(2026, 11, 19, 5, 45))
        #expect(ClockMath.nextFire(of: past, after: friday, in: denver) == nil)
    }

    @Test("The mockup's next-alarm line")
    func until() {
        #expect(ClockMath.until(moment(2026, 11, 21, 7, 30), from: friday) == "in 16 h 55 min")
        #expect(ClockMath.until(friday.addingTimeInterval(20), from: friday) == "in 1 min")
        #expect(ClockMath.until(friday.addingTimeInterval(3 * 3600), from: friday) == "in 3 h")
        #expect(ClockMath.until(friday.addingTimeInterval(50 * 3600), from: friday) == "in 2 d 2 h")
    }

    @Test("World clock offsets and days, daylight saving included")
    func offsets() {
        let local = TimeZone(identifier: "America/Denver")!
        #expect(ClockMath.offset(of: TimeZone(identifier: "America/New_York")!, from: local, at: friday) == "2 h ahead")
        #expect(ClockMath.offset(of: TimeZone(identifier: "Asia/Kolkata")!, from: local, at: friday) == "12 h 30 min ahead")
        #expect(ClockMath.offset(of: TimeZone(identifier: "Pacific/Honolulu")!, from: local, at: friday) == "3 h behind")
        #expect(ClockMath.offset(of: local, from: local, at: friday) == "Same time")
        // Phoenix keeps no daylight saving, so in July it matches Los Angeles, and in November Denver.
        #expect(ClockMath.offset(of: TimeZone(identifier: "America/Phoenix")!, from: local, at: friday) == "Same time")
        #expect(ClockMath.offset(of: TimeZone(identifier: "America/Phoenix")!, from: local, at: moment(2026, 7, 1, 12)) == "1 h behind")
        let evening = moment(2026, 11, 20, 20, 0)
        #expect(ClockMath.dayWord(in: TimeZone(identifier: "Asia/Tokyo")!, local: local, at: evening) == "Tomorrow")
        #expect(ClockMath.dayWord(in: TimeZone(identifier: "America/New_York")!, local: local, at: friday) == nil)
        #expect(ClockMath.dayWord(in: TimeZone(identifier: "Pacific/Honolulu")!, local: local, at: moment(2026, 11, 20, 1, 0)) == "Yesterday")
    }

    @Test func durations() {
        #expect(ClockMath.duration(768) == "12:48")
        #expect(ClockMath.duration(3723) == "1:02:03")
        #expect(ClockMath.duration(7.42, hundredths: true) == "00:07.42")
        #expect(ClockMath.length(180) == "3 min")
        #expect(ClockMath.length(5400) == "1 h 30 min")
        #expect(ClockMath.length(45) == "45 s")
        #expect(ClockMath.repeatText([2, 3, 4, 5, 6], calendar: denver) == "Weekdays")
        #expect(ClockMath.repeatText([3, 5], calendar: denver) == "Tue, Thu")
        #expect(ClockMath.repeatText([], calendar: denver) == "Once")
    }

    @Test("Bedtime's reminder lands on the night before each wake-up day")
    func bedtime() {
        let sleep = SleepSchedule(bedHour: 22, bedMinute: 30, wakeHour: 6, wakeMinute: 30, weekdays: [2], remindMinutes: 15, isOn: true)
        let parts = NotificationAlarms.bedtimeParts(sleep)
        #expect(parts.count == 1)
        #expect(parts[0].0 == 1)
        #expect(parts[0].1.hour == 22 && parts[0].1.minute == 15)
        // Bed after midnight is the wake-up's own day.
        let late = SleepSchedule(bedHour: 0, bedMinute: 30, wakeHour: 8, wakeMinute: 0, weekdays: [7], remindMinutes: 0, isOn: true)
        #expect(NotificationAlarms.bedtimeParts(late)[0].0 == 7)
        // A reminder before a just-after-midnight bedtime moves to the night before.
        let early = SleepSchedule(bedHour: 0, bedMinute: 10, wakeHour: 8, wakeMinute: 0, weekdays: [1], remindMinutes: 15, isOn: true)
        #expect(NotificationAlarms.bedtimeParts(early)[0].0 == 7)
        #expect(NotificationAlarms.bedtimeParts(early)[0].1.hour == 23)
        #expect(sleep.sleepMinutes == 8 * 60)
    }

    @Test("Cities come from the device's time zones, searched by word")
    func cities() {
        #expect(CityList.all.contains { $0.name == "New York" && $0.timeZoneID == "America/New_York" })
        #expect(!CityList.all.contains { $0.timeZoneID.hasPrefix("Etc/") || $0.timeZoneID == "GMT" })
        #expect(CityList.search("york").contains { $0.name == "New York" })
        #expect(CityList.search("phoe").map(\.name) == ["Phoenix"])
    }
}

@Suite struct StopwatchAndTimerTests {
    @Test("The stopwatch counts from its start, laps, and marks the fastest and slowest")
    func stopwatch() {
        var watch = Stopwatch()
        #expect(watch.isReset)
        watch.start(at: friday)
        watch.lap(at: friday.addingTimeInterval(10))
        watch.lap(at: friday.addingTimeInterval(14))
        watch.lap(at: friday.addingTimeInterval(30))
        #expect(watch.laps == [10, 4, 16])
        #expect(watch.fastestLap == 1)
        #expect(watch.slowestLap == 2)
        watch.stop(at: friday.addingTimeInterval(31))
        #expect(watch.elapsed(at: friday.addingTimeInterval(500)) == 31)
        #expect(watch.currentLap(at: friday.addingTimeInterval(500)) == 1)
        watch.reset(at: friday)
        #expect(watch.isReset)
    }

    @Test("A timer is a start and a length, so pausing keeps what's left")
    func timer() {
        var timer = RunningTimer(label: "Pasta", seconds: 1200, startedAt: friday)
        #expect(timer.remaining(at: friday.addingTimeInterval(432)) == 768)
        #expect(timer.endsAt == friday.addingTimeInterval(1200))
        timer.pause(at: friday.addingTimeInterval(432))
        #expect(timer.endsAt == nil)
        #expect(timer.remaining(at: friday.addingTimeInterval(9000)) == 768)
        timer.resume(at: friday.addingTimeInterval(1000))
        #expect(timer.endsAt == friday.addingTimeInterval(1768))
        #expect(timer.isFinished(at: friday.addingTimeInterval(1768)))
    }
}

@Suite struct ClockMergeTests {
    @Test("Two devices' cities and presets come together, later of each, removals kept")
    func merge() {
        let early = friday
        let late = friday.addingTimeInterval(60)
        let tokyo = WorldCity(name: "Tokyo", timeZoneID: "Asia/Tokyo", order: 1, updatedAt: early)
        var renamed = tokyo
        renamed.name = "Tōkyō"
        renamed.updatedAt = late
        let london = WorldCity(name: "London", timeZoneID: "Europe/London", order: 2, updatedAt: early)
        var one = ClockItems(cities: [tokyo, london])
        one.remove(london.id, at: late)
        let other = ClockItems(cities: [renamed, london])
        let merged = ClockItems.merged(one, other)
        #expect(merged == ClockItems.merged(other, one))
        #expect(merged.shownCities.map(\.name) == ["Tōkyō"])
        #expect(ClockItems.merged(merged, merged) == merged)
        // Adding London back later brings it back.
        var back = london
        back.updatedAt = late.addingTimeInterval(1)
        #expect(ClockItems.merged(merged, ClockItems(cities: [back])).shownCities.count == 2)
    }
}

@Suite struct ClockBookTests {
    @Test("Both records are sealed: no city, label or preset is readable in storage")
    func sealed() async throws {
        let blobs = MemoryBlobs()
        let book = ClockBook(store: blobs, rootKey: try ContentRootKey.generate())
        try await book.save(ClockItems(cities: [WorldCity(name: "Reykjavik", timeZoneID: "Atlantic/Reykjavik", order: 1, updatedAt: friday)]))
        try await book.save(ClockDevice(alarms: [ClockAlarm(hour: 5, minute: 45, label: "Flight to Phoenix")]))
        let text = String(decoding: blobs.everything, as: UTF8.self)
        #expect(!text.contains("Reykjavik"))
        #expect(!text.contains("Phoenix"))
        #expect(try await book.loadItems()?.shownCities.first?.name == "Reykjavik")
        #expect(try await book.loadDevice()?.alarms.first?.label == "Flight to Phoenix")
    }

    @Test("Only the synced record reaches sync; alarms stay on the device")
    func deviceStaysHome() async throws {
        let book = ClockBook(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
        try await book.save(ClockItems())
        try await book.save(ClockDevice(alarms: [ClockAlarm(hour: 6, minute: 15)]))
        let ids = try await book.sealedObjectIDs()
        #expect(ids.count == 1)
        let object = try #require(try await book.sealedObject(ids[0]))
        #expect(object.kind == .clockItems)
        #expect(book.kinds == [.clockItems])
    }
}

/// The two-user test (issue 204, step 7): user B can't read A's clock record, and sync won't take it.
@Suite struct ClockTwoUserTests {
    @Test("User 2 can't read user 1's clock record, and their records never share an ID")
    func staysPrivate() async throws {
        let user1 = ClockBook(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
        try await user1.save(ClockItems(cities: [WorldCity(name: "Lagos", timeZoneID: "Africa/Lagos", order: 1, updatedAt: friday)]))
        let id = try #require(try await user1.sealedObjectIDs().first)
        let object = try #require(try await user1.sealedObject(id))

        let user2 = ClockBook(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
        try await user2.save(ClockItems())
        #expect(try await user2.sealedObjectIDs() != [id])
        await #expect(throws: (any Error).self) { try await user2.store(object, ifLocalHash: nil) }
        #expect(try await user2.loadItems()?.shownCities.isEmpty == true)
    }
}

@MainActor
@Suite struct ClockModelTests {
    func model(_ alarms: FakeAlarms = FakeAlarms(), at clock: TestClock = TestClock(friday)) async throws -> (ClockModel, ClockBook) {
        let book = ClockBook(store: MemoryBlobs(), rootKey: try ContentRootKey.generate())
        let model = ClockModel(
            book: book, scheduler: alarms, sounds: ClockSounds(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            calendar: denver, now: { clock.date }
        )
        await model.load()
        return (model, book)
    }

    @Test("A new person starts with the mockup's presets and no alarms")
    func starting() async throws {
        let (model, _) = try await model()
        #expect(model.phase == .ready)
        #expect(model.items.shownPresets.map(\.name) == ["Tea", "Eggs", "Focus"])
        #expect(model.alarms.isEmpty)
        #expect(model.glance == ModuleGlance(lines: ["No alarms yet"], isQuiet: true))
    }

    @Test("Saving an alarm sets it with iOS and shows it as next")
    func alarms() async throws {
        let fake = FakeAlarms()
        let (model, book) = try await model(fake)
        let run = ClockAlarm(hour: 7, minute: 30, label: "Long run", weekdays: [7])
        await model.save(run)
        #expect(fake.alarms[run.id] != nil)
        #expect(model.nextAlarm?.date == moment(2026, 11, 21, 7, 30))
        #expect(model.glance?.lines.first?.hasSuffix("in 16 h 55 min") == true)
        await model.setOn(run.id, false)
        #expect(fake.alarms[run.id] == nil)
        #expect(model.nextAlarm == nil)
        #expect(try await book.loadDevice()?.alarms.first?.isOn == false)
        await model.deleteAlarm(run.id)
        #expect(model.alarms.isEmpty)
    }

    @Test("An alarm iOS refuses shows a warning and isn't counted as set")
    func refused() async throws {
        let fake = FakeAlarms()
        let (model, _) = try await model(fake)
        let alarm = ClockAlarm(hour: 6, minute: 15)
        fake.refuse = [alarm.id]
        await model.save(alarm)
        #expect(model.failed.contains(alarm.id))
        #expect(model.nextAlarm == nil)
    }

    @Test("Totality asks once, the first time an alarm is set")
    func asksOnce() async throws {
        let fake = FakeAlarms(state: .notAsked)
        let (model, _) = try await model(fake)
        #expect(model.access == .notAsked)
        await model.save(ClockAlarm(hour: 6, minute: 0))
        #expect(model.access == .allowed)
        #expect(fake.alarms.count == 1)
    }

    @Test("Another module's alarm is set once, on its day, with its source")
    func fromAnotherModule() async throws {
        let fake = FakeAlarms(ringsAsAlarm: false)
        let (model, _) = try await model(fake)
        let fire = moment(2026, 11, 24, 5, 45)
        let made = try await model.make(AlarmDraft(label: "Flight to Phoenix", fireDate: fire, source: TaskSource(module: .calendar, itemID: "own-1", title: "Flight to Phoenix")))
        #expect(made.isRealAlarm == false)
        #expect(made.line.contains("silent switch"))
        let alarm = try #require(model.alarms.first)
        #expect(alarm.date == fire)
        #expect(alarm.weekdays.isEmpty)
        #expect(alarm.source?.module == .calendar)
        #expect(fake.alarms[alarm.id] != nil)
    }

    @Test("Timers pause, resume and cancel with iOS, and a finished one is dropped")
    func timers() async throws {
        let fake = FakeAlarms()
        let clock = TestClock(friday)
        let (model, book) = try await model(fake, at: clock)
        await model.start(model.items.shownPresets[0])
        let id = try #require(model.timers.first?.id)
        #expect(fake.timers[id] != nil)
        clock.date = friday.addingTimeInterval(60)
        await model.pause(id)
        #expect(fake.timers[id] == nil)
        #expect(model.timers.first?.remaining(at: clock.date.addingTimeInterval(999)) == 120)
        await model.resume(id)
        #expect(fake.timers[id] != nil)
        clock.date = friday.addingTimeInterval(1000)
        model.dropFinishedTimers()
        #expect(model.timers.isEmpty)
        await model.startTimer(seconds: 60, label: "Laundry")
        let laundry = try #require(model.timers.first?.id)
        await model.cancel(laundry)
        #expect(fake.timers[laundry] == nil)
        #expect(model.timers.isEmpty)
        _ = book
    }

    @Test("Bedtime's wake-up is an alarm and its reminder goes to iOS")
    func bedtime() async throws {
        let fake = FakeAlarms()
        let (model, _) = try await model(fake)
        await model.save(SleepSchedule(isOn: true))
        #expect(fake.alarms[SleepSchedule.wakeID] != nil)
        #expect(fake.bedtime?.isOn == true)
        #expect(model.nextAlarm?.alarm.id == SleepSchedule.wakeID)
        await model.save(SleepSchedule(isOn: false))
        #expect(fake.alarms[SleepSchedule.wakeID] == nil)
        #expect(fake.bedtime == nil)
    }

    @Test("Cities and the stopwatch are kept in the synced record")
    func citiesAndStopwatch() async throws {
        let (model, book) = try await model()
        await model.addCity(CityList.Choice(name: "Tokyo", region: "Asia", timeZoneID: "Asia/Tokyo"))
        await model.addCity(CityList.Choice(name: "Tokyo", region: "Asia", timeZoneID: "Asia/Tokyo"))
        await model.addCity(CityList.Choice(name: "London", region: "Europe", timeZoneID: "Europe/London"))
        await model.moveCities(from: [1], to: 0)
        #expect(model.items.shownCities.map(\.name) == ["London", "Tokyo"])
        await model.startStopwatch()
        #expect(try await book.loadItems()?.stopwatch.isRunning == true)
        await model.removeCity(model.items.shownCities[0].id)
        #expect(try await book.loadItems()?.shownCities.map(\.name) == ["Tokyo"])
    }

    @Test("The module finds cities and alarms, and offers cities as places")
    func module() async throws {
        let (model, book) = try await model()
        await model.addCity(CityList.Choice(name: "Phoenix", region: "America", timeZoneID: "America/Phoenix"))
        await model.save(ClockAlarm(hour: 5, minute: 45, label: "Flight to Phoenix"))
        let module = ClockModule(book: book) { draft in try await model.make(draft) }
        let hits = try await module.search("phoenix")
        #expect(hits.map(\.title) == ["Phoenix", "Flight to Phoenix"])
        let places = await module.places()
        #expect(places.map(\.timeZoneID) == ["America/Phoenix"])
        let registry = try ModuleRegistry(handlers: [module])
        #expect(registry.alarmMaker != nil)
        #expect(await registry.places(except: .calendar).count == 1)
    }

    @Test("Tones are drawn on the device as WAV files")
    func tones() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sounds = ClockSounds(folder: folder)
        let name = try #require(sounds.file(for: .tone(.chime), own: []))
        let data = try Data(contentsOf: folder.appendingPathComponent(name))
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(Double(data.count) / (ClockSounds.rate * 2) < ClockSounds.longest)
        #expect(sounds.file(for: .standard, own: []) == nil)
        #expect(sounds.file(for: .own(UUID()), own: []) == nil)
    }
}
