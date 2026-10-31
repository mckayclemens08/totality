import Foundation
import Observation
import TotalityCore

/// One row on a calendar: either the person's own event or one read from the device.
public struct CalendarEntry: Identifiable, Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case own(EventOccurrence)
        case device(DeviceEvent)
    }

    public let source: Source

    public var id: String {
        switch source {
        case .own(let occurrence): "own-\(occurrence.id)"
        case .device(let event): "device-\(event.id)"
        }
    }

    public var title: String {
        switch source {
        case .own(let occurrence): occurrence.event.displayTitle
        case .device(let event): event.title.isEmpty ? "Untitled event" : event.title
        }
    }

    public var location: String {
        switch source {
        case .own(let occurrence): occurrence.event.location
        case .device(let event): event.location
        }
    }

    public var isAllDay: Bool {
        switch source {
        case .own(let occurrence): occurrence.event.isAllDay
        case .device(let event): event.isAllDay
        }
    }

    public var start: Date {
        switch source {
        case .own(let occurrence): occurrence.start
        case .device(let event): event.start
        }
    }

    public var end: Date {
        switch source {
        case .own(let occurrence): occurrence.end
        case .device(let event): event.end
        }
    }

    /// The days it appears on. An all-day event of the person's own is the same dates in any zone.
    func days(in display: Calendar) -> [CalendarDay] {
        let first, last: CalendarDay
        if case .own(let occurrence) = source, occurrence.event.isAllDay {
            first = CalendarDay(occurrence.start, in: occurrence.event.ownCalendar)
            last = CalendarDay(occurrence.end, in: occurrence.event.ownCalendar)
        } else {
            first = CalendarDay(start, in: display)
            last = CalendarDay(end > start ? end.addingTimeInterval(-1) : start, in: display)
        }
        var days = [first]
        while let latest = days.last, latest < last, days.count < 366 {
            days.append(latest.adding(days: 1, in: display))
        }
        return days
    }
}

/// What the editor works on, in the person's own time.
public struct EventDraft: Equatable, Sendable {
    public var title = ""
    public var location = ""
    public var notes = ""
    public var start: Date
    public var end: Date
    public var isAllDay = false
    public var frequency: RepeatRule.Frequency?
    public var until: Date?
    public var reminderMinutes: Int?
    public var attachments: [ContentRef] = []

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    init(_ occurrence: EventOccurrence, display: Calendar) {
        let event = occurrence.event
        title = event.title
        location = event.location
        notes = event.notes
        isAllDay = event.isAllDay
        if event.isAllDay {
            start = CalendarDay(occurrence.start, in: event.ownCalendar).start(in: display)
            end = CalendarDay(occurrence.end, in: event.ownCalendar).start(in: display)
        } else {
            start = occurrence.start
            end = occurrence.end
        }
        frequency = event.repeatRule?.frequency
        until = event.repeatRule?.until?.start(in: display)
        reminderMinutes = event.reminderMinutes
        attachments = event.attachments
    }
}

public enum EditScope: Sendable {
    case thisOccurrence, allOccurrences
}

/// What the Calendar screens show. Own events live in the vault. Device events stay in memory here.
@MainActor
@Observable
public final class CalendarModel {
    public enum Phase: Equatable {
        case loading, ready, failed
    }

    public enum Mode: String, CaseIterable, Sendable {
        case agenda, month

        public var name: String {
            switch self {
            case .agenda: "Agenda"
            case .month: "Month"
            }
        }
    }

    public static let reminderChoices: [Int?] = [nil, 0, 5, 10, 15, 30, 60, 1_440]
    private static let agendaDays = 90
    private static let hiddenKey = "calendar.hiddenDeviceCalendars"

    public private(set) var phase = Phase.loading
    public private(set) var events: [CalendarEvent] = []
    public private(set) var unreadable = 0
    public private(set) var deviceAccess = DeviceCalendarAccess.notAsked
    public private(set) var deviceCalendars: [DeviceCalendar] = []
    public private(set) var hiddenCalendars: Set<String>
    public private(set) var month: CalendarDay
    public var selectedDay: CalendarDay
    public var mode: Mode
    /// A problem to show the person, cleared when they dismiss it.
    public var notice: String?

    public let display: Calendar
    private let vault: CalendarVault
    private let devices: any DeviceCalendarSource
    private let reminders: any ReminderScheduler
    private let registry: ModuleRegistry?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var deviceEvents: [DeviceEvent] = []
    private var entriesByDay: [CalendarDay: [CalendarEntry]] = [:]

    public init(
        vault: CalendarVault, devices: any DeviceCalendarSource, reminders: any ReminderScheduler,
        registry: ModuleRegistry? = nil, startingMode: Mode, display: Calendar = CalendarModel.personalCalendar,
        defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.vault = vault
        self.devices = devices
        self.reminders = reminders
        self.registry = registry
        self.mode = startingMode
        self.display = display
        self.defaults = defaults
        self.now = now
        let today = CalendarDay(now(), in: display)
        month = today.firstOfMonth
        selectedDay = today
        // Opaque IDs from the system, not calendar names.
        hiddenCalendars = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    public nonisolated static var personalCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        return calendar
    }

    public var today: CalendarDay {
        CalendarDay(now(), in: display)
    }

    public func entries(on day: CalendarDay) -> [CalendarEntry] {
        entriesByDay[day] ?? []
    }

    /// Days from today on that have something on them.
    public var agenda: [(day: CalendarDay, entries: [CalendarEntry])] {
        let start = today
        let end = start.adding(days: Self.agendaDays, in: display)
        return entriesByDay.keys.filter { $0 >= start && $0 <= end }.sorted().map { ($0, entriesByDay[$0] ?? []) }
    }

    public func load() async {
        do {
            let listing = try await vault.list()
            events = listing.events
            unreadable = listing.unreadable
            phase = .ready
        } catch {
            phase = .failed
            return
        }
        refreshDevice()
        rebuild()
        await syncReminders()
    }

    public func show(monthsFromNow offset: Int) {
        month = month.adding(months: offset, in: display)
        refreshDevice()
        rebuild()
    }

    public func showToday() {
        month = today.firstOfMonth
        selectedDay = today
        refreshDevice()
        rebuild()
    }

    /// The selected day only means something in the month view. The agenda starts from now.
    public func newDraft() -> EventDraft {
        let day = mode == .month ? selectedDay : today
        let base = day == today
            ? display.nextDate(after: now(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now()
            : display.date(byAdding: .hour, value: 9, to: day.start(in: display)) ?? now()
        return EventDraft(start: base, end: base.addingTimeInterval(3_600))
    }

    public func draft(for occurrence: EventOccurrence) -> EventDraft {
        EventDraft(occurrence, display: display)
    }

    // MARK: Saving

    /// Returns false when nothing was saved, so the editor stays open with what was typed.
    public func create(_ draft: EventDraft) async -> Bool {
        guard let times = times(from: draft, keeping: nil) else { return false }
        let event = CalendarEvent(
            title: Self.cleaned(draft.title), location: Self.cleaned(draft.location), notes: draft.notes,
            start: times.start, end: times.end, isAllDay: draft.isAllDay, timeZoneID: times.zone,
            repeatRule: rule(from: draft), reminderMinutes: draft.reminderMinutes, attachments: draft.attachments,
            createdAt: now(), updatedAt: now()
        )
        return await commit(saving: [event], needsReminders: draft.reminderMinutes != nil)
    }

    public func update(_ occurrence: EventOccurrence, with draft: EventDraft, scope: EditScope) async -> Bool {
        guard let times = times(from: draft, keeping: occurrence.event) else { return false }
        var series = occurrence.event
        if scope == .thisOccurrence, series.repeatRule != nil {
            // One occurrence leaves the series and becomes its own event. The copy is written first,
            // so a failure can leave a duplicate but can't lose the event.
            let single = CalendarEvent(
                title: Self.cleaned(draft.title), location: Self.cleaned(draft.location), notes: draft.notes,
                start: times.start, end: times.end, isAllDay: draft.isAllDay, timeZoneID: times.zone,
                reminderMinutes: draft.reminderMinutes, attachments: draft.attachments,
                createdAt: now(), updatedAt: now()
            )
            series.skipped.insert(occurrence.start)
            series.updatedAt = now()
            return await commit(saving: [single, series], needsReminders: draft.reminderMinutes != nil)
        }

        if series.repeatRule != nil, series.isAllDay == draft.isAllDay {
            // Moving one occurrence moves the whole series by the same amount.
            let shift = times.start.timeIntervalSince(occurrence.start)
            series.start = series.start.addingTimeInterval(shift)
            series.end = series.start.addingTimeInterval(times.end.timeIntervalSince(times.start))
            series.skipped = Set(series.skipped.map { $0.addingTimeInterval(shift) })
        } else {
            // Switching a series between timed and all-day starts it again from here.
            series.start = times.start
            series.end = times.end
            series.skipped = []
        }
        series.title = Self.cleaned(draft.title)
        series.location = Self.cleaned(draft.location)
        series.notes = draft.notes
        series.isAllDay = draft.isAllDay
        series.timeZoneID = times.zone
        series.repeatRule = rule(from: draft)
        series.reminderMinutes = draft.reminderMinutes
        series.attachments = draft.attachments
        series.updatedAt = now()
        return await commit(saving: [series], needsReminders: draft.reminderMinutes != nil)
    }

    public func delete(_ occurrence: EventOccurrence, scope: EditScope) async {
        var event = occurrence.event
        do {
            if scope == .thisOccurrence, event.repeatRule != nil {
                event.skipped.insert(occurrence.start)
                event.updatedAt = now()
                try await vault.save(event)
            } else {
                try await vault.delete(event.id)
            }
        } catch {
            notice = "\(event.displayTitle) couldn't be deleted."
        }
        await load()
    }

    private func commit(saving changed: [CalendarEvent], needsReminders: Bool) async -> Bool {
        do {
            for event in changed { try await vault.save(event) }
        } catch {
            notice = "That event wasn't saved. Try again."
            return false
        }
        if needsReminders, await !reminders.requestPermission() {
            notice = "The event is saved, but notifications are off for Totality, so its reminder won't show."
        }
        await load()
        return true
    }

    private func times(from draft: EventDraft, keeping original: CalendarEvent?) -> (start: Date, end: Date, zone: String)? {
        let first = CalendarDay(draft.start, in: display)
        if let until = draft.until, draft.frequency != nil, CalendarDay(until, in: display) < first {
            notice = "A repeat can't end before the event starts."
            return nil
        }
        if draft.isAllDay {
            let last = CalendarDay(draft.end, in: display)
            guard last >= first else {
                notice = "An event can't end before it starts."
                return nil
            }
            var gmt = Calendar(identifier: .gregorian)
            gmt.timeZone = .gmt
            return (first.start(in: gmt), last.start(in: gmt), CalendarEvent.allDayZone)
        }
        guard draft.end >= draft.start else {
            notice = "An event can't end before it starts."
            return nil
        }
        let zone = original.flatMap { $0.isAllDay ? nil : $0.timeZoneID } ?? display.timeZone.identifier
        return (draft.start, draft.end, zone)
    }

    private func rule(from draft: EventDraft) -> RepeatRule? {
        draft.frequency.map { RepeatRule(frequency: $0, until: draft.until.map { CalendarDay($0, in: display) }) }
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Device calendars

    public func allowDeviceCalendars() async {
        if await devices.requestAccess() {
            refreshDevice()
            rebuild()
        } else {
            deviceAccess = devices.access()
            notice = "Totality can't see your calendars. You can allow it in Settings."
        }
    }

    public func setVisible(_ visible: Bool, calendar: DeviceCalendar) {
        if visible {
            hiddenCalendars.remove(calendar.id)
        } else {
            hiddenCalendars.insert(calendar.id)
        }
        defaults.set(hiddenCalendars.sorted(), forKey: Self.hiddenKey)
        refreshDevice()
        rebuild()
    }

    private func refreshDevice() {
        deviceAccess = devices.access()
        deviceCalendars = devices.calendars()
        let window = visibleWindow
        let chosen = Set(deviceCalendars.map(\.id)).subtracting(hiddenCalendars)
        deviceEvents = devices.events(
            from: window.first.start(in: display),
            to: window.last.adding(days: 1, in: display).start(in: display),
            calendarIDs: chosen
        )
    }

    // MARK: Attachments

    public func attachableContent() async -> [ContentRef] {
        var refs: [ContentRef] = []
        for provider in registry?.providers(for: .calendar) ?? [] {
            refs += (try? await provider.attachable()) ?? []
        }
        return refs
    }

    /// Nil means the attached content is gone, so the event shows that instead of a dead link.
    public func current(_ ref: ContentRef) async -> ContentRef? {
        let provider = registry?.providers(for: .calendar).first { $0.module == ref.module }
        return try? await provider?.current(ref)
    }

    // MARK: Building the days

    private var visibleWindow: (first: CalendarDay, last: CalendarDay) {
        let start = today
        let monthEnd = month.adding(months: 1, in: display).adding(days: -1, in: display)
        return (min(start, month), max(start.adding(days: Self.agendaDays, in: display), monthEnd))
    }

    private func rebuild() {
        let window = visibleWindow
        var own: [CalendarEntry] = []
        for event in events {
            own += event.occurrences(from: window.first, through: window.last, in: display).map { CalendarEntry(source: .own($0)) }
        }
        var days: [CalendarDay: [CalendarEntry]] = [:]
        for entry in own + deviceEvents.map({ CalendarEntry(source: .device($0)) }) {
            for day in entry.days(in: display) { days[day, default: []].append(entry) }
        }
        entriesByDay = days.mapValues { entries in
            entries.sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
        }
    }

    private func syncReminders() async {
        await reminders.replace(with: ReminderPlanner.plan(for: events, now: now(), display: display))
    }
}
