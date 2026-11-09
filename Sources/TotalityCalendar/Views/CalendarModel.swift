import AuthenticationServices
import Foundation
import Observation
import TotalityCore

/// Opens Google's page in the system's web sign-in sheet and hands back where Google sent the person.
public typealias GoogleWebSignIn = @MainActor (_ page: URL, _ callbackScheme: String) async throws -> URL

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
        case month, day, week, schedule

        public var systemImage: String {
            switch self {
            case .month: "calendar"
            case .day: "calendar.day.timeline.left"
            case .week: "rectangle.split.3x1"
            case .schedule: "list.bullet"
            }
        }
    }

    public static let reminderChoices: [Int?] = [nil, 0, 5, 10, 15, 30, 60, 1_440]
    private static let scheduleDays = 90
    private nonisolated static let hiddenKey = "calendar.hiddenDeviceCalendars"
    /// Seven columns can't be read on a phone.
    public nonisolated static var platformWeekSpan: Int {
        #if os(macOS)
        7
        #else
        3
        #endif
    }

    public private(set) var phase = Phase.loading
    public private(set) var events: [CalendarEvent] = []
    public private(set) var unreadable = 0
    public private(set) var deviceAccess = DeviceCalendarAccess.notAsked
    public private(set) var deviceCalendars: [DeviceCalendar] = []
    public private(set) var hiddenCalendars: Set<String>
    public private(set) var month: CalendarDay
    public private(set) var selectedDay: CalendarDay
    public var mode: Mode
    /// A problem to show the person, cleared when they dismiss it.
    public var notice: String?
    /// True once this device syncs, which decides what the screen can truthfully say about recovery.
    public var isSynced = false
    /// A search result to open. The home screen takes it from here.
    public var requestedHit: SearchHit?
    private var requestedDay: CalendarDay?

    public let display: Calendar
    public let weekSpan: Int
    private let vault: CalendarVault
    private let devices: any DeviceCalendarSource
    private let reminders: any ReminderScheduler
    private let registry: ModuleRegistry?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var deviceEvents: [DeviceEvent] = []
    private let google: GoogleCalendars?
    /// Connected Google accounts and their calendars, as last kept on this device.
    public private(set) var googleAccounts: [GoogleCalendarAccount] = []
    /// Google accounts connected for Mail or Photos that haven't allowed Calendar yet.
    public private(set) var googleNeedsAllowing: [String] = []
    /// Accounts the last sync couldn't read. What was kept from before still shows.
    public private(set) var googleProblems: [String: GoogleCalendarProblem] = [:]
    /// True while Google Calendar is being read, for the spinner.
    public private(set) var isSyncingGoogle = false
    /// True while Google's page is open or its answer is being checked.
    public private(set) var isConnectingGoogle = false
    private var googleEvents: [DeviceEvent] = []
    private var entriesByDay: [CalendarDay: [CalendarEntry]] = [:]
    private var built: (first: CalendarDay, last: CalendarDay)?

    public init(
        vault: CalendarVault, devices: any DeviceCalendarSource, reminders: any ReminderScheduler,
        registry: ModuleRegistry? = nil, google: GoogleCalendars? = nil, startingMode: Mode = .month, display: Calendar = CalendarModel.personalCalendar,
        weekSpan: Int = CalendarModel.platformWeekSpan, defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.vault = vault
        self.devices = devices
        self.reminders = reminders
        self.registry = registry
        self.google = google
        self.mode = startingMode
        self.display = display
        self.weekSpan = weekSpan
        self.defaults = defaults
        self.now = now
        let today = CalendarDay(now(), in: display)
        month = today.firstOfMonth
        selectedDay = today
        hiddenCalendars = Self.hiddenCalendars(in: defaults)
    }

    /// Opaque IDs from the system, not calendar names.
    public nonisolated static func hiddenCalendars(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: hiddenKey) ?? [])
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

    public var currentDate: Date {
        now()
    }

    public func entries(on day: CalendarDay) -> [CalendarEntry] {
        entriesByDay[day] ?? []
    }

    /// Today's week, starting where the device says weeks start.
    public var thisWeek: [CalendarDay] {
        let weekday = display.component(.weekday, from: today.start(in: display))
        let first = today.adding(days: -((weekday - display.firstWeekday + 7) % 7), in: display)
        return (0..<7).map { first.adding(days: $0, in: display) }
    }

    /// The weekday letters in the order the device starts its week.
    public var weekdayLetters: [String] {
        let symbols = display.veryShortStandaloneWeekdaySymbols
        let first = display.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Days from today on that have something on them.
    public var schedule: [(day: CalendarDay, entries: [CalendarEntry])] {
        let start = today
        let end = start.adding(days: Self.scheduleDays, in: display)
        return entriesByDay.keys.filter { $0 >= start && $0 <= end }.sorted().map { ($0, entriesByDay[$0] ?? []) }
    }

    /// The timed event on now, or the soonest one after it.
    public var nextEntry: CalendarEntry? {
        let current = now()
        for (_, entries) in schedule {
            if let next = entries.filter({ !$0.isAllDay && $0.end > current }).min(by: { $0.start < $1.start }) {
                return next
            }
        }
        return nil
    }

    /// For the home tile: what's next, how much is on today, then the rest of today. Nil until the
    /// Calendar opens, so a tile can't say nothing's on while it's loading.
    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        let current = now()
        let next = nextEntry
        let todays = entries(on: today)
        let count = switch todays.count {
        case 0: "Nothing today"
        case 1: "1 thing today"
        default: "\(todays.count) things today"
        }
        let rest = restOfToday(after: next).map { entry in
            entry.isAllDay ? entry.title : "\(entry.start.formatted(date: .omitted, time: .shortened)) \(entry.title)"
        }
        return ModuleGlance(
            lines: (next.map { [glanceLine(for: $0, at: current)] } ?? []) + [count] + rest,
            isQuiet: next == nil && todays.isEmpty
        )
    }

    private func restOfToday(after next: CalendarEntry?) -> [CalendarEntry] {
        let current = now()
        return entries(on: today).filter { $0.id != next?.id && ($0.isAllDay || $0.end > current) }
    }

    /// What a line of the glance is about: an event, or today for the line that counts them.
    public func glanceTarget(at line: Int) -> Target? {
        let next = nextEntry
        let targets = (next.map { [Target.entry($0)] } ?? []) + [.day(today)] + restOfToday(after: next).map { .entry($0) }
        return targets.indices.contains(line) ? targets[line] : nil
    }

    private func glanceLine(for entry: CalendarEntry, at current: Date) -> String {
        if entry.start <= current { return "\(entry.title), now" }
        if CalendarDay(entry.start, in: display) == today {
            return "\(entry.title), \(entry.start.formatted(date: .omitted, time: .shortened))"
        }
        return "\(entry.title), \(entry.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }

    public func name(of mode: Mode) -> String {
        switch mode {
        case .month: "Month"
        case .day: "Day"
        case .week: weekSpan == 7 ? "Week" : "\(weekSpan) Days"
        case .schedule: "Schedule"
        }
    }

    /// The columns of the day and week timelines. A full week starts where the device says weeks start.
    public var visibleDays: [CalendarDay] {
        guard mode == .week else { return [selectedDay] }
        var first = selectedDay
        if weekSpan == 7 {
            let weekday = display.component(.weekday, from: selectedDay.start(in: display))
            first = selectedDay.adding(days: -((weekday - display.firstWeekday + 7) % 7), in: display)
        }
        return (0..<weekSpan).map { first.adding(days: $0, in: display) }
    }

    public var title: String {
        switch mode {
        case .month:
            written(month, .dateTime.month(.wide).year())
        case .day:
            written(selectedDay, .dateTime.weekday(.wide).month(.abbreviated).day())
        case .week:
            weekTitle
        case .schedule:
            name(of: .schedule)
        }
    }

    private var weekTitle: String {
        let days = visibleDays
        guard let first = days.first, let last = days.last else { return "" }
        let end = first.month == last.month ? "\(last.day)" : written(last, .dateTime.month(.abbreviated).day())
        return "\(written(first, .dateTime.month(.abbreviated).day())) to \(end)"
    }

    public func heading(for day: CalendarDay) -> String {
        if day == today { return "Today" }
        if day == today.adding(days: 1, in: display) { return "Tomorrow" }
        return written(day, .dateTime.weekday(.wide).month(.wide).day())
    }

    /// Written in the calendar's own zone, or midnight can land on the day before.
    func written(_ day: CalendarDay, _ style: Date.FormatStyle) -> String {
        var style = style
        style.timeZone = display.timeZone
        style.calendar = display
        return day.start(in: display).formatted(style)
    }

    /// Whether Today has anywhere to go.
    public var isShowingToday: Bool {
        switch mode {
        case .month: selectedDay == today
        case .day, .week: visibleDays.contains(today)
        case .schedule: true
        }
    }

    public var canMove: Bool {
        mode != .schedule
    }

    /// Stops anything that could write, for when every blob is about to be rewritten under a new key.
    public func stopForKeyChange() async {
        await vault.close()
        await google?.close()
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
        if let google { googleAccounts = await google.kept() }
        refreshDevice()
        rebuild()
        await syncReminders()
    }

    public func show(monthsFromNow offset: Int) {
        let target = month.adding(months: offset, in: display)
        select(today.firstOfMonth == target ? today : target)
    }

    public func showToday() {
        select(today)
    }

    /// Opening the Calendar always lands on the month, with today's events below (owner, 2026-10-31).
    public func showFront() {
        mode = .month
        showToday()
    }

    public func select(_ day: CalendarDay) {
        selectedDay = day
        month = day.firstOfMonth
        fillIn()
    }

    /// Something on the home page to show once the Calendar is open.
    public enum Target: Sendable, Hashable {
        case entry(CalendarEntry)
        case day(CalendarDay)
    }

    /// An event goes the way a search result does, so it gets the same check that it's still there.
    public func request(_ target: Target) {
        switch target {
        case .entry(let entry):
            requestedHit = SearchHit(module: .calendar, itemID: entry.id, title: entry.title, date: entry.start)
        case .day(let day):
            requestedDay = day
        }
    }

    public func takeRequestedDay() {
        guard let day = requestedDay else { return }
        requestedDay = nil
        select(day)
        mode = .day
    }

    /// Goes to the day of the requested result and hands back its event. It can be gone by now,
    /// because results are only as fresh as the moment they were found.
    public func takeRequestedEntry() -> CalendarEntry? {
        guard let hit = requestedHit else { return nil }
        requestedHit = nil
        if let date = hit.date {
            let day = CalendarDay(date, in: display)
            select(day)
            if let entry = entries(on: day).first(where: { $0.id == hit.itemID }) { return entry }
        }
        notice = "This event is no longer here."
        return nil
    }

    /// In Month, the first tap picks a day and the second opens it.
    public func choose(_ day: CalendarDay) {
        if day == selectedDay {
            mode = .day
        } else {
            select(day)
        }
    }

    /// One swipe or arrow: forward with 1, back with -1.
    public func move(by steps: Int) {
        switch mode {
        case .month: show(monthsFromNow: steps)
        case .day: select(selectedDay.adding(days: steps, in: display))
        case .week: select(selectedDay.adding(days: steps * weekSpan, in: display))
        case .schedule: break
        }
    }

    /// The selected day means nothing in Schedule, which starts from now.
    public func newDraft() -> EventDraft {
        let day = mode == .schedule ? today : selectedDay
        if day == today {
            let base = display.nextDate(after: now(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now()
            return EventDraft(start: base, end: base.addingTimeInterval(3_600))
        }
        return newDraft(on: day, hour: 9)
    }

    /// For an hour tapped on the timeline.
    public func newDraft(on day: CalendarDay, hour: Int) -> EventDraft {
        let base = display.date(bySettingHour: hour, minute: 0, second: 0, of: day.start(in: display)) ?? now()
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

    /// What's on screen was older than what a sync brought in, so the latest shows first.
    private func showLatest() async {
        await load()
        notice = "This event changed on another device. Open it again to see the latest."
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
            return await commit(saving: [single, series], basedOn: occurrence.event, needsReminders: draft.reminderMinutes != nil)
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
        return await commit(saving: [series], basedOn: occurrence.event, needsReminders: draft.reminderMinutes != nil)
    }

    public func delete(_ occurrence: EventOccurrence, scope: EditScope) async {
        var event = occurrence.event
        do {
            if scope == .thisOccurrence, event.repeatRule != nil {
                event.skipped.insert(occurrence.start)
                event.updatedAt = now()
                try await vault.save([event], ifStillAt: occurrence.event)
            } else {
                try await vault.delete(event.id, ifStillAt: occurrence.event)
            }
        } catch CalendarError.changed, CalendarError.notFound {
            await showLatest()
            return
        } catch {
            notice = "\(event.displayTitle) couldn't be deleted."
        }
        await load()
    }

    private func commit(saving changed: [CalendarEvent], basedOn original: CalendarEvent? = nil, needsReminders: Bool) async -> Bool {
        do {
            if let original {
                try await vault.save(changed, ifStillAt: original)
            } else {
                for event in changed { try await vault.save(event) }
            }
        } catch CalendarError.changed, CalendarError.notFound {
            await showLatest()
            return false
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
        googleEvents = GoogleCalendars.events(
            in: googleAccounts, from: window.first.start(in: display), to: window.last.adding(days: 1, in: display).start(in: display)
        )
    }

    // MARK: Google Calendar

    /// Whether this build can connect Google Calendar.
    public var canUseGoogle: Bool { google?.isAvailable == true }

    /// Reads Google Calendar again. Only changes come back after the first time. Runs when the Calendar
    /// opens, when it's pulled down, and every few minutes while it's open.
    public func refreshGoogle() async {
        guard let google, google.isAvailable, !isSyncingGoogle else { return }
        isSyncingGoogle = true
        defer { isSyncingGoogle = false }
        let result = await google.sync()
        googleAccounts = result.accounts
        googleNeedsAllowing = result.needsAllowing
        googleProblems = result.problems
        refreshDevice()
        rebuild()
    }

    /// One line for the Calendar to show about Google, or nil when there's nothing to say.
    public var googleStatus: String? {
        if let problem = googleProblems.values.first { return problem.message }
        return nil
    }

    /// Connects a Google account for Calendar, or, with an account already connected for Mail or
    /// Photos, allows Calendar on it with one tap.
    public func connectGoogle(_ account: String? = nil, signingIn web: GoogleWebSignIn) async {
        guard let google, let authorization = await google.authorization(for: account), !isConnectingGoogle else { return }
        isConnectingGoogle = true
        defer { isConnectingGoogle = false }
        do {
            let callback = try await web(authorization.url, authorization.callbackScheme)
            _ = try await google.finish(authorization, callback: callback)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch is CancellationError {
            return
        } catch let problem as GoogleCalendarProblem {
            notice = problem == .notAllowed
                ? "Google Calendar wasn't allowed on Google's page, so nothing was added. Try again and leave Calendar ticked."
                : problem.message
            return
        } catch {
            notice = GoogleCalendarProblem.from(error).message
            return
        }
        await refreshGoogle()
    }

    public func setVisible(_ visible: Bool, googleCalendar: GoogleCalendarState, account: String) async {
        guard let google else { return }
        do {
            try await google.setOn(visible, calendar: googleCalendar.id, account: account)
        } catch {
            notice = "That calendar couldn't be changed. Close the Calendar and try again."
            return
        }
        if visible {
            await refreshGoogle()
        } else {
            googleAccounts = await google.kept()
            refreshDevice()
            rebuild()
        }
    }

    /// What else disconnecting this account ends, for the screen to say first.
    public func googleAlsoEnds(_ account: String) async -> Set<GoogleUse> {
        await google?.alsoEnds(account) ?? []
    }

    public func disconnectGoogle(_ account: String) async {
        guard let google else { return }
        await google.disconnect(account)
        googleAccounts.removeAll { $0.address == account }
        googleNeedsAllowing.removeAll { $0 == account }
        googleProblems[account] = nil
        refreshDevice()
        rebuild()
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

    /// Wide enough for the month, the schedule, any week around the selected day, and the home tile,
    /// which shows this month and this week wherever the Calendar was left.
    private var visibleWindow: (first: CalendarDay, last: CalendarDay) {
        let start = today
        let monthEnd = month.adding(months: 1, in: display).adding(days: -1, in: display)
        return (
            min(start.adding(days: -6, in: display), start.firstOfMonth, month, selectedDay.adding(days: -7, in: display)),
            max(start.adding(days: Self.scheduleDays, in: display), monthEnd, selectedDay.adding(days: 7, in: display))
        )
    }

    /// Moving between days stays cheap until it reaches days that haven't been built.
    private func fillIn() {
        let window = visibleWindow
        if let built, built.first <= window.first, built.last >= window.last { return }
        refreshDevice()
        rebuild()
    }

    private func rebuild() {
        let window = visibleWindow
        built = window
        var own: [CalendarEntry] = []
        for event in events {
            own += event.occurrences(from: window.first, through: window.last, in: display).map { CalendarEntry(source: .own($0)) }
        }
        var days: [CalendarDay: [CalendarEntry]] = [:]
        for entry in own + (deviceEvents + googleEvents).map({ CalendarEntry(source: .device($0)) }) {
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
