import Foundation
import TotalityCore

/// The Calendar's entry in the registry. Other modules can't attach events yet.
public struct CalendarModule: ContentHandler {
    public let module = ModuleID.calendar
    public let kinds: Set<ContentKind> = [.event]
    private let vault: CalendarVault?
    private let devices: (any DeviceCalendarSource)?
    private let google: GoogleCalendars?
    private let hidden: @Sendable () -> Set<String>
    private let display: Calendar
    private let now: @Sendable () -> Date
    private let refresh: @Sendable () async -> Void

    /// `refresh` brings every calendar source up to date, quietly.
    public init(
        vault: CalendarVault? = nil, devices: (any DeviceCalendarSource)? = nil, google: GoogleCalendars? = nil,
        hidden: @escaping @Sendable () -> Set<String> = { [] },
        display: Calendar = CalendarModel.personalCalendar, now: @escaping @Sendable () -> Date = { Date() },
        refresh: @escaping @Sendable () async -> Void = {}
    ) {
        self.refresh = refresh
        self.vault = vault
        self.devices = devices
        self.google = google
        self.hidden = hidden
        self.display = display
        self.now = now
    }
}

extension CalendarModule: ModuleSearcher {
    /// Device and Google calendars are read here and go no further, the same as on the Calendar's screens.
    public func search(_ query: String) async throws -> [SearchHit] {
        let terms = SearchText.terms(in: query)
        guard let vault, !terms.isEmpty else { return [] }
        let events = try await vault.list().events
        try Task.checkCancellation()
        let current = now()
        let today = CalendarDay(current, in: display)
        let chosen = Set(devices?.calendars().map(\.id) ?? []).subtracting(hidden())
        let from = today.adding(days: -CalendarSearch.reach, in: display).start(in: display)
        let to = today.adding(days: CalendarSearch.reach, in: display).start(in: display)
        let deviceEvents = (devices?.events(from: from, to: to, calendarIDs: chosen) ?? []) + (await google?.events(from: from, to: to) ?? [])
        return CalendarSearch.hits(terms: terms, events: events, deviceEvents: deviceEvents, display: display, now: current)
    }
}

/// The app keeps this module fresh before it's opened, through `AppRefresh`, without showing it.
extension CalendarModule: ModuleRefresher {
    public func refreshAhead() async {
        await refresh()
    }
}

/// What's on each day, for another module to show beside its own things, like Tasks' Upcoming. Only titles
/// and times leave, and only in memory.
extension CalendarModule: AgendaProvider {
    public func agenda(from start: Date, to end: Date) async -> [AgendaItem] {
        guard start < end else { return [] }
        let first = CalendarDay(start, in: display)
        let last = CalendarDay(end.addingTimeInterval(-1), in: display)
        var entries: [CalendarEntry] = []
        if let vault, let events = try? await vault.list().events {
            for event in events {
                entries += event.occurrences(from: first, through: last, in: display).map { CalendarEntry(source: .own($0)) }
            }
        }
        let chosen = Set(devices?.calendars().map(\.id) ?? []).subtracting(hidden())
        let outside = (devices?.events(from: start, to: end, calendarIDs: chosen) ?? []) + (await google?.events(from: start, to: end) ?? [])
        entries += outside.map { CalendarEntry(source: .device($0)) }
        return entries.compactMap { entry in
            guard entry.isAllDay else {
                return AgendaItem(id: entry.id, title: entry.title, start: entry.start, end: entry.end, isAllDay: false)
            }
            // An all-day item keeps its dates, wherever the person is.
            let days = entry.days(in: display)
            guard let firstDay = days.first, let lastDay = days.last else { return nil }
            return AgendaItem(
                id: entry.id, title: entry.title, start: firstDay.start(in: display),
                end: lastDay.adding(days: 1, in: display).start(in: display), isAllDay: true
            )
        }
    }
}
