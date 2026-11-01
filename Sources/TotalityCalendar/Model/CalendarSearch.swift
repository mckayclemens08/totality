import Foundation
import TotalityCore

/// Finds events by title, location, notes, and the names of what's attached. Each event shows once,
/// however many times it repeats: at its next occurrence, or its latest if it's over.
enum CalendarSearch {
    /// How far either side of today to look: a repeating event's next occurrence, and device events.
    static let reach = 366

    static func hits(terms: [String], events: [CalendarEvent], deviceEvents: [DeviceEvent], display: Calendar, now: Date) -> [SearchHit] {
        guard !terms.isEmpty else { return [] }
        var found: [Found] = []
        for event in events {
            let fields = [event.location, event.notes] + event.attachments.map(\.preview.title)
            guard matches(terms, title: event.title, fields: fields),
                  let occurrence = occurrence(of: event, display: display, now: now)
            else { continue }
            found.append(Found(entry: CalendarEntry(source: .own(occurrence)), fields: fields))
        }
        let matching = deviceEvents.filter { matches(terms, title: $0.title, fields: [$0.location, $0.notes]) }
        // A device calendar hands over each repeat as its own event.
        for repeats in Dictionary(grouping: matching, by: { [$0.title, $0.location, $0.calendarTitle] }).values {
            let upcoming = repeats.filter { isAhead(CalendarEntry(source: .device($0)), display: display, now: now) }
            guard let event = upcoming.min(by: { $0.start < $1.start }) ?? repeats.max(by: { $0.start < $1.start }) else { continue }
            found.append(Found(entry: CalendarEntry(source: .device(event)), fields: [event.location, event.notes]))
        }
        let ahead = found.filter { isAhead($0.entry, display: display, now: now) }.sorted { $0.entry.start < $1.entry.start }
        let past = found.filter { !isAhead($0.entry, display: display, now: now) }.sorted { $0.entry.start > $1.entry.start }
        return (ahead + past).map { hit(for: $0, terms: terms, display: display) }
    }

    private struct Found {
        let entry: CalendarEntry
        let fields: [String]
    }

    private static func matches(_ terms: [String], title: String, fields: [String]) -> Bool {
        terms.allSatisfy { term in
            ([title] + fields).contains { SearchText.find(term, in: $0) != nil }
        }
    }

    private static func isAhead(_ entry: CalendarEntry, display: Calendar, now: Date) -> Bool {
        if entry.isAllDay {
            return (entry.days(in: display).last ?? CalendarDay(entry.start, in: display)) >= CalendarDay(now, in: display)
        }
        return entry.end > now || entry.start >= now
    }

    /// Nil when nothing is left of it, like a series with every occurrence deleted.
    static func occurrence(of event: CalendarEvent, display: Calendar, now: Date) -> EventOccurrence? {
        let today = CalendarDay(now, in: display)
        let ahead = event.occurrences(from: today, through: today.adding(days: reach, in: display), in: display)
        if let next = ahead.first(where: { isAhead(CalendarEntry(source: .own($0)), display: display, now: now) }) {
            return next
        }
        let behind = event.occurrences(from: today.adding(days: -reach, in: display), through: today, in: display)
        if let latest = behind.last { return latest }
        let first = CalendarDay(event.start, in: display)
        return event.occurrences(from: first, through: first.adding(days: reach, in: display), in: display).first
    }

    private static func hit(for found: Found, terms: [String], display: Calendar) -> SearchHit {
        let entry = found.entry
        let firstDay = entry.days(in: display).first ?? CalendarDay(entry.start, in: display)
        let date = entry.isAllDay ? firstDay.start(in: display) : entry.start
        return SearchHit(
            module: .calendar, itemID: entry.id, title: entry.title,
            detail: written(date, isAllDay: entry.isAllDay, in: display),
            snippet: snippet(terms: terms, fields: found.fields), date: date
        )
    }

    private static func written(_ date: Date, isAllDay: Bool, in display: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()
        if !isAllDay { style = style.hour().minute() }
        style.timeZone = display.timeZone
        style.calendar = display
        return date.formatted(style.locale(display.locale ?? .autoupdatingCurrent))
    }

    /// The first field with a match. A match in the title alone needs no snippet.
    private static func snippet(terms: [String], fields: [String]) -> String? {
        for field in fields {
            if let match = terms.lazy.compactMap({ SearchText.find($0, in: field) }).first {
                return SearchText.excerpt(of: field, around: match)
            }
        }
        return nil
    }
}
