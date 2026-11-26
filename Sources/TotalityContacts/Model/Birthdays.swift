import Foundation
import TotalityCore

/// When birthdays fall: the next one for a card, the ones coming up, and the Calendar's all-day items
/// (issue 205, section 5). Worked out on this device from the sealed cards.
public enum Birthdays {
    /// One birthday coming up.
    public struct Upcoming: Identifiable, Hashable, Sendable {
        public let card: ContactCard
        /// The start of the day it falls on.
        public let date: Date
        /// How old they'll be, when the card has the year.
        public let turning: Int?
        /// Whole days from today: 0 is today.
        public let daysAway: Int

        public var id: UUID { card.id }
    }

    /// The day `birthday` next falls on, today included. A 29 February birthday is on the 28th in other years.
    public static func next(_ birthday: ContactCard.Birthday, from now: Date, in calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        let thisYear = calendar.component(.year, from: today)
        for year in thisYear...(thisYear + 1) {
            if let date = date(of: birthday, in: year, calendar: calendar), date >= today { return date }
        }
        return nil
    }

    static func date(of birthday: ContactCard.Birthday, in year: Int, calendar: Calendar) -> Date? {
        var day = birthday.day
        if birthday.month == 2, day == 29, !isLeap(year) { day = 28 }
        return calendar.date(from: DateComponents(year: year, month: birthday.month, day: day))
    }

    static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Everyone whose birthday is within `days` of today, soonest first.
    public static func upcoming(_ cards: [ContactCard], from now: Date, within days: Int = 60, in calendar: Calendar) -> [Upcoming] {
        let today = calendar.startOfDay(for: now)
        return cards.compactMap { card -> Upcoming? in
            guard !card.isDeleted, let birthday = card.birthday, birthday.isValid,
                  let date = next(birthday, from: now, in: calendar),
                  let away = calendar.dateComponents([.day], from: today, to: date).day, away <= days
            else { return nil }
            let turning = birthday.year.map { calendar.component(.year, from: date) - $0 }.flatMap { $0 > 0 ? $0 : nil }
            return Upcoming(card: card, date: date, turning: turning, daysAway: away)
        }
        .sorted { ($0.daysAway, $0.card.sortKey) < ($1.daysAway, $1.card.sortKey) }
    }

    /// "Today", "Tomorrow", "Sunday" within a week, else "22 November".
    public static func when(_ upcoming: Upcoming, in calendar: Calendar) -> String {
        switch upcoming.daysAway {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6:
            var style = Date.FormatStyle().weekday(.wide)
            style.timeZone = calendar.timeZone
            return upcoming.date.formatted(style)
        default:
            return dayMonth(upcoming.date, in: calendar)
        }
    }

    /// "22 November".
    public static func dayMonth(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.day, .month], from: date)
        guard let day = parts.day, let month = parts.month, calendar.monthSymbols.indices.contains(month - 1) else { return "" }
        return "\(day) \(calendar.monthSymbols[month - 1])"
    }

    /// "Priya Patel's birthday is Sunday".
    public static func headline(_ upcoming: Upcoming, in calendar: Calendar) -> String {
        "\(upcoming.card.shownName)'s birthday is \(when(upcoming, in: calendar))"
    }

    /// "22 November · turning 27".
    public static func detail(_ upcoming: Upcoming, in calendar: Calendar) -> String {
        let day = dayMonth(upcoming.date, in: calendar)
        guard let turning = upcoming.turning else { return day }
        return "\(day) · turning \(turning)"
    }

    /// The birthday as the card shows it, such as "14 March" or "14 March 1999".
    public static func shown(_ birthday: ContactCard.Birthday, in calendar: Calendar) -> String {
        guard let date = date(of: birthday, in: birthday.year ?? 2000, calendar: calendar) else { return "" }
        let day = dayMonth(date, in: calendar)
        return birthday.year.map { "\(day) \($0)" } ?? day
    }

    /// The birthdays that fall between `start` and `end`, as all-day items for the Calendar. Titles only:
    /// no number, address or note crosses over.
    public static func agenda(_ cards: [ContactCard], from start: Date, to end: Date, in calendar: Calendar) -> [AgendaItem] {
        guard start < end else { return [] }
        let first = calendar.component(.year, from: start), last = calendar.component(.year, from: end)
        guard last - first < 5 else { return [] }
        var items: [AgendaItem] = []
        for card in cards where !card.isDeleted {
            guard let birthday = card.birthday, birthday.isValid else { continue }
            for year in first...last {
                guard let day = date(of: birthday, in: year, calendar: calendar),
                      let after = calendar.date(byAdding: .day, value: 1, to: day),
                      day < end, after > start
                else { continue }
                let turning = birthday.year.map { year - $0 }.flatMap { $0 > 0 ? "Turning \($0)" : nil }
                items.append(AgendaItem(
                    id: card.id.uuidString, title: "\(card.shownName)'s birthday", start: day, end: after, isAllDay: true,
                    module: .contacts, detail: turning
                ))
            }
        }
        return items
    }
}
