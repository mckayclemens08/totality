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

    public init(
        vault: CalendarVault? = nil, devices: (any DeviceCalendarSource)? = nil, google: GoogleCalendars? = nil,
        hidden: @escaping @Sendable () -> Set<String> = { [] },
        display: Calendar = CalendarModel.personalCalendar, now: @escaping @Sendable () -> Date = { Date() }
    ) {
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
