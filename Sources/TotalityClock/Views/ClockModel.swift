import Foundation
import Observation
import TotalityCore

/// The Clock's state and actions. Everything runs on the device: the sealed records are read from here,
/// and alarms are set with iOS.
@MainActor
@Observable
public final class ClockModel {
    public enum Phase: Equatable { case loading, ready, failed }
    public enum Tab: String, CaseIterable, Hashable {
        case world, alarms, timers, stopwatch

        public var title: String {
            switch self {
            case .world: "World"
            case .alarms: "Alarms"
            case .timers: "Timers"
            case .stopwatch: "Stopwatch"
            }
        }
    }

    public private(set) var phase: Phase = .loading
    public private(set) var items = ClockItems()
    public private(set) var device = ClockDevice()
    public private(set) var access: AlarmAccess = .notAsked
    /// Alarms iOS wouldn't take. They show a warning and aren't counted as set.
    public private(set) var failed: Set<UUID> = []
    public var notice: String?
    /// A tab another screen asked for, like the Home tile's timers.
    public var requestedTab: Tab?

    @ObservationIgnored private let book: ClockBook?
    @ObservationIgnored let scheduler: any AlarmScheduling
    @ObservationIgnored private let sounds: ClockSounds
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored let calendar: Calendar

    public init(
        book: ClockBook?, scheduler: any AlarmScheduling = SystemAlarms.make(), sounds: ClockSounds = ClockSounds(),
        calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.book = book
        self.scheduler = scheduler
        self.sounds = sounds
        self.calendar = calendar
        clock = now
    }

    public var now: Date { clock() }
    /// True when alarms ring as real alarms here (AlarmKit, iOS 26 and later).
    public var ringsAsAlarm: Bool { scheduler.ringsAsAlarm }

    // MARK: Loading

    /// Reads both sealed records and sets every alarm with iOS again, so what rings matches what's shown.
    public func load() async {
        guard let book else {
            phase = .failed
            return
        }
        do {
            let stored = try await book.loadItems()
            items = stored ?? ClockItems.starting(at: now)
            if stored == nil { items = try await book.save(items) }
            device = try await book.loadDevice() ?? ClockDevice()
            phase = .ready
        } catch {
            phase = .failed
            return
        }
        access = await scheduler.access()
        dropFinishedTimers()
        await scheduleAll()
    }

    /// Another device's cities, presets or stopwatch may have come in through sync.
    public func reload() async {
        guard let book, phase == .ready, let stored = try? await book.loadItems() else { return }
        let merged = ClockItems.merged(stored, items)
        if merged != items { items = merged }
    }

    public func requestAccess() async {
        access = await scheduler.requestAccess()
        if access == .allowed { await scheduleAll() }
    }

    /// Asks iOS how things stand, for coming back from Settings.
    public func refreshAccess() async {
        let was = access
        access = await scheduler.access()
        if was != .allowed, access == .allowed { await scheduleAll() }
    }

    private func scheduleAll() async {
        guard access == .allowed else { return }
        for alarm in device.alarms { await place(alarm) }
        await placeSleep()
    }

    // MARK: World clock

    public func addCity(_ choice: CityList.Choice) async {
        guard !items.shownCities.contains(where: { $0.timeZoneID == choice.timeZoneID }) else { return }
        let order = (items.shownCities.map(\.order).max() ?? 0) + 1
        items.cities.append(WorldCity(name: choice.name, timeZoneID: choice.timeZoneID, order: order, updatedAt: now))
        await keepItems()
    }

    public func removeCity(_ id: UUID) async {
        items.remove(id, at: now)
        await keepItems()
    }

    public func moveCities(from source: IndexSet, to destination: Int) async {
        var cities = items.shownCities
        cities.move(fromOffsets: source, toOffset: destination)
        let stamp = now
        for (index, city) in cities.enumerated() {
            guard let at = items.cities.firstIndex(where: { $0.id == city.id }) else { continue }
            items.cities[at].order = Double(index + 1)
            items.cities[at].updatedAt = stamp
        }
        await keepItems()
    }

    // MARK: Alarms

    public var alarms: [ClockAlarm] {
        device.alarms.sorted { ($0.hour, $0.minute, $0.id.uuidString) < ($1.hour, $1.minute, $1.id.uuidString) }
    }

    /// The soonest alarm that's set, bedtime's wake-up included.
    public var nextAlarm: (alarm: ClockAlarm, date: Date)? {
        let set = device.alarms.filter { !failed.contains($0.id) } + (device.sleep.isOn ? [device.sleep.wakeAlarm] : [])
        return ClockMath.nextAlarm(in: set, after: now, in: calendar)
    }

    public func save(_ alarm: ClockAlarm) async {
        var alarm = alarm
        alarm.label = String(alarm.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if let index = device.alarms.firstIndex(where: { $0.id == alarm.id }) {
            device.alarms[index] = alarm
        } else {
            device.alarms.append(alarm)
        }
        await keepDevice()
        await askOnce()
        await place(alarm)
    }

    public func setOn(_ id: UUID, _ isOn: Bool) async {
        guard var alarm = device.alarms.first(where: { $0.id == id }) else { return }
        alarm.isOn = isOn
        await save(alarm)
    }

    public func deleteAlarm(_ id: UUID) async {
        device.alarms.removeAll { $0.id == id }
        failed.remove(id)
        await scheduler.cancelAlarm(id)
        await keepDevice()
    }

    /// An alarm another module asked for. Nothing calls this without the person pressing Set.
    public func make(_ draft: AlarmDraft) async throws -> AlarmMade {
        let parts = calendar.dateComponents([.hour, .minute], from: draft.fireDate)
        let alarm = ClockAlarm(
            hour: parts.hour ?? 0, minute: parts.minute ?? 0, label: draft.label, date: draft.fireDate, source: draft.source
        )
        await save(alarm)
        if failed.contains(alarm.id) { throw AlarmSchedulingError.failed }
        return AlarmMade(id: alarm.id, label: alarm.label, fireDate: draft.fireDate, isRealAlarm: ringsAsAlarm)
    }

    private func place(_ alarm: ClockAlarm) async {
        do {
            try await scheduler.schedule(alarm, sound: sounds.file(for: alarm.sound, own: device.sounds))
            failed.remove(alarm.id)
        } catch {
            if alarm.isOn { failed.insert(alarm.id) } else { failed.remove(alarm.id) }
        }
    }

    /// Totality asks once, the first time something is set (section 7).
    private func askOnce() async {
        if access == .notAsked { access = await scheduler.requestAccess() }
    }

    // MARK: Bedtime

    public func save(_ sleep: SleepSchedule) async {
        device.sleep = sleep
        await keepDevice()
        if sleep.isOn { await askOnce() }
        await placeSleep()
    }

    private func placeSleep() async {
        let wake = device.sleep.wakeAlarm
        if device.sleep.isOn {
            await place(wake)
        } else {
            await scheduler.cancelAlarm(wake.id)
            failed.remove(wake.id)
        }
        await scheduler.bedtimeReminder(device.sleep.isOn ? device.sleep : nil)
    }

    // MARK: Timers

    public var timers: [RunningTimer] { device.timers }

    public func startTimer(seconds: Int, label: String) async {
        guard seconds > 0 else { return }
        let timer = RunningTimer(label: String(label.prefix(40)), seconds: seconds, startedAt: now)
        device.timers.append(timer)
        await keepDevice()
        await askOnce()
        await run(timer)
    }

    public func start(_ preset: TimerPreset) async {
        await startTimer(seconds: preset.seconds, label: preset.name)
    }

    public func pause(_ id: UUID) async {
        guard let index = device.timers.firstIndex(where: { $0.id == id }) else { return }
        device.timers[index].pause(at: now)
        await scheduler.pause(device.timers[index])
        await keepDevice()
    }

    public func resume(_ id: UUID) async {
        guard let index = device.timers.firstIndex(where: { $0.id == id }) else { return }
        device.timers[index].resume(at: now)
        await keepDevice()
        await run(device.timers[index])
    }

    public func cancel(_ id: UUID) async {
        device.timers.removeAll { $0.id == id }
        failed.remove(id)
        await scheduler.cancelTimer(id)
        await keepDevice()
    }

    private func run(_ timer: RunningTimer) async {
        do {
            try await scheduler.start(timer, sound: sounds.file(for: timer.sound, own: device.sounds), at: now)
            failed.remove(timer.id)
        } catch {
            failed.insert(timer.id)
        }
    }

    /// Timers that rang while the app was closed are done.
    func dropFinishedTimers() {
        let stamp = now
        let finished = device.timers.filter { $0.isFinished(at: stamp) }
        guard !finished.isEmpty else { return }
        device.timers.removeAll { $0.isFinished(at: stamp) }
        Task { await keepDevice() }
    }

    public func addPreset(name: String, seconds: Int) async {
        guard seconds > 0 else { return }
        let order = (items.shownPresets.map(\.order).max() ?? 0) + 1
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items.presets.append(TimerPreset(name: cleaned.isEmpty ? ClockMath.length(seconds) : String(cleaned.prefix(24)), seconds: seconds, order: order, updatedAt: now))
        await keepItems()
    }

    public func removePreset(_ id: UUID) async {
        items.remove(id, at: now)
        await keepItems()
    }

    // MARK: Stopwatch

    public var stopwatch: Stopwatch { items.stopwatch }

    public func startStopwatch() async {
        items.stopwatch.start(at: now)
        await keepItems()
    }

    public func stopStopwatch() async {
        items.stopwatch.stop(at: now)
        await keepItems()
    }

    public func lap() async {
        items.stopwatch.lap(at: now)
        await keepItems()
    }

    public func resetStopwatch() async {
        items.stopwatch.reset(at: now)
        await keepItems()
    }

    // MARK: Sounds

    public var ownSounds: [OwnSound] { device.sounds }

    public func addSound(from url: URL, named name: String) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let sound = try sounds.add(from: url, named: name)
            device.sounds.append(sound)
            await keepDevice()
        } catch {
            notice = "That sound couldn't be added. Try a different file."
        }
    }

    public func removeSound(_ id: UUID) async {
        guard let sound = device.sounds.first(where: { $0.id == id }) else { return }
        device.sounds.removeAll { $0.id == id }
        // Anything ringing with it goes back to the standard sound.
        for index in device.alarms.indices where device.alarms[index].sound == .own(id) { device.alarms[index].sound = .standard }
        if device.sleep.sound == .own(id) { device.sleep.sound = .standard }
        sounds.remove(sound)
        await keepDevice()
        await scheduleAll()
    }

    public func soundName(_ sound: ClockSound) -> String {
        switch sound {
        case .standard: "Standard"
        case .tone(let tone): tone.name
        case .own(let id): device.sounds.first { $0.id == id }?.name ?? "Standard"
        }
    }

    // MARK: Keeping

    private func keepItems() async {
        guard let book else { return }
        do { items = try await book.save(items) } catch { notice = "This change couldn't be saved on this iPhone." }
    }

    private func keepDevice() async {
        guard let book else { return }
        device.updatedAt = now
        do { try await book.save(device) } catch { notice = "This change couldn't be saved on this iPhone." }
    }

    // MARK: Home

    /// The tile's lines: the next alarm, or a running timer.
    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        let stamp = now
        if let timer = device.timers.filter({ !$0.isPaused }).min(by: { $0.remaining(at: stamp) < $1.remaining(at: stamp) }) {
            return ModuleGlance(lines: ["\(timer.label.isEmpty ? "Timer" : timer.label) · \(ClockMath.duration(timer.remaining(at: stamp)))"])
        }
        if let next = nextAlarm {
            return ModuleGlance(lines: ["\(next.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())) \(ClockMath.until(next.date, from: stamp))"])
        }
        return ModuleGlance(lines: ["No alarms yet"], isQuiet: true)
    }
}
