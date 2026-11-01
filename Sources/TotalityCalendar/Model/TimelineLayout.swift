import Foundation

/// Where one timed event sits on a day's timeline. Events that overlap share the width.
struct TimelineBlock: Identifiable {
    let entry: CalendarEntry
    let startMinute: Int
    let endMinute: Int
    let column: Int
    let columns: Int

    var id: String { entry.id }
}

enum TimelineLayout {
    static let minutesInDay = 1_440
    /// Short enough to be accurate, tall enough to tap and read.
    static let shortestMinutes = 30

    /// Clock minutes, so a 9 AM event lines up with 9 AM on a day the clocks change.
    static func minute(of date: Date, on day: CalendarDay, in display: Calendar) -> Int {
        guard date >= day.start(in: display) else { return 0 }
        guard date < day.adding(days: 1, in: display).start(in: display) else { return minutesInDay }
        let parts = display.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func blocks(for entries: [CalendarEntry], on day: CalendarDay, in display: Calendar) -> [TimelineBlock] {
        let spans = entries.filter { !$0.isAllDay }.map { entry in
            let start = min(minute(of: entry.start, on: day, in: display), minutesInDay - shortestMinutes)
            let end = max(minute(of: entry.end, on: day, in: display), start + shortestMinutes)
            return (entry: entry, start: start, end: end)
        }
        .sorted { ($0.start, $0.end, $0.entry.id) < ($1.start, $1.end, $1.entry.id) }

        var blocks: [TimelineBlock] = []
        var group: [(entry: CalendarEntry, start: Int, end: Int, column: Int)] = []
        var columnEnds: [Int] = []
        var groupEnd = 0

        func finishGroup() {
            blocks += group.map {
                TimelineBlock(entry: $0.entry, startMinute: $0.start, endMinute: $0.end, column: $0.column, columns: columnEnds.count)
            }
            group = []
            columnEnds = []
        }

        for span in spans {
            if span.start >= groupEnd { finishGroup() }
            let column = columnEnds.firstIndex { $0 <= span.start } ?? columnEnds.count
            if column == columnEnds.count {
                columnEnds.append(span.end)
            } else {
                columnEnds[column] = span.end
            }
            group.append((span.entry, span.start, span.end, column))
            groupEnd = max(groupEnd, span.end)
        }
        finishGroup()
        return blocks
    }
}
