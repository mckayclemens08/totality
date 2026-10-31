import EventKit
import Foundation

public struct DeviceCalendar: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let account: String
}

/// An event from a calendar on the device, like Apple's or a Google account's. Totality doesn't own
/// or encrypt these. They're read when needed, and never written to Totality's storage.
public struct DeviceEvent: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let location: String
    public let notes: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarTitle: String
}

public enum DeviceCalendarAccess: Sendable {
    case notAsked, allowed, denied
}

public protocol DeviceCalendarSource: Sendable {
    func access() -> DeviceCalendarAccess
    func requestAccess() async -> Bool
    func calendars() -> [DeviceCalendar]
    func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [DeviceEvent]
}

/// EventKit's store has no concurrency annotations, but Apple documents it as safe across threads.
public final class SystemCalendarSource: DeviceCalendarSource, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func access() -> DeviceCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    public func requestAccess() async -> Bool {
        let allowed = (try? await store.requestFullAccessToEvents()) ?? false
        if allowed { store.reset() }
        return allowed
    }

    public func calendars() -> [DeviceCalendar] {
        guard access() == .allowed else { return [] }
        return store.calendars(for: .event)
            .map { DeviceCalendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    public func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [DeviceEvent] {
        guard access() == .allowed else { return [] }
        let chosen = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        return store.events(matching: predicate).map { event in
            DeviceEvent(
                id: "\(event.eventIdentifier ?? "")-\(event.startDate.timeIntervalSince1970)",
                title: event.title ?? "",
                location: event.location ?? "",
                notes: event.notes ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar?.title ?? ""
            )
        }
    }
}
