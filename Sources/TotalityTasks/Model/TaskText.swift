import Foundation

/// The words Tasks shows for dates, in the person's own calendar and language.
public enum TaskText {
    /// "Today", "Tomorrow", "Friday" for the coming week, otherwise "Nov 20", with the year when it isn't this one.
    public static func day(_ day: TaskDay, today: TaskDay, in calendar: Calendar) -> String {
        let ahead = today.days(to: day, in: calendar)
        switch ahead {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return formatted(day, .dateTime.weekday(.wide), in: calendar)
        default:
            let style: Date.FormatStyle = day.year == today.year ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()
            return formatted(day, style, in: calendar)
        }
    }

    /// A day heading for Upcoming and the Logbook, like "Tuesday, Nov 17".
    public static func heading(_ day: TaskDay, today: TaskDay, in calendar: Calendar) -> String {
        let ahead = today.days(to: day, in: calendar)
        let date = formatted(day, .dateTime.weekday(.wide).month(.abbreviated).day(), in: calendar)
        switch ahead {
        case 0: return "Today · " + date
        case 1: return "Tomorrow · " + date
        case -1: return "Yesterday · " + date
        default: return day.year == today.year ? date : formatted(day, .dateTime.weekday(.wide).month(.abbreviated).day().year(), in: calendar)
        }
    }

    public static func time(_ time: TaskTime, in calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = calendar.timeZone
        style.calendar = calendar
        let date = TaskDay(year: 2026, month: 1, day: 15).date(at: time, in: calendar)
        return date.formatted(style.locale(calendar.locale ?? .autoupdatingCurrent))
    }

    /// The deadline as the quiet line says it.
    public static func deadline(_ deadline: TaskDay, today: TaskDay, in calendar: Calendar) -> String {
        let ahead = today.days(to: deadline, in: calendar)
        if ahead < 0 { return ahead == -1 ? "Due yesterday" : "Overdue by \(-ahead) days" }
        return "Due " + day(deadline, today: today, in: calendar).lowercasedIfRelative
    }

    /// The deadline in the middle of a line: "due Friday", "overdue by 3 days".
    public static func deadlinePhrase(_ deadline: TaskDay, today: TaskDay, in calendar: Calendar) -> String {
        let words = self.deadline(deadline, today: today, in: calendar)
        return words.prefix(1).lowercased() + words.dropFirst()
    }

    /// The one quiet line under a task's title: its date, deadline, tag, or checklist count.
    public static func quietLine(for task: TaskItem, in bucket: TaskBucket, today: TaskDay, calendar: Calendar) -> String? {
        var parts: [String] = []
        if let when = task.when, bucket != .today, bucket != .upcoming {
            parts.append(day(when, today: today, in: calendar))
        }
        if let time = task.time, task.when != nil { parts.append(self.time(time, in: calendar)) }
        if let deadline = task.deadline { parts.append(self.deadline(deadline, today: today, in: calendar)) }
        if !task.checklist.isEmpty { parts.append("\(task.checklistDone) of \(task.checklist.count)") }
        if let tag = task.tags.first { parts.append("#" + tag) }
        if bucket == .logbook, let done = task.completedAt {
            var style = Date.FormatStyle.dateTime.hour().minute()
            style.timeZone = calendar.timeZone
            parts = ["Done " + done.formatted(style)] + parts.filter { !$0.hasPrefix("Due") && !$0.hasPrefix("Overdue") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatted(_ day: TaskDay, _ style: Date.FormatStyle, in calendar: Calendar) -> String {
        var style = style
        style.timeZone = calendar.timeZone
        style.calendar = calendar
        return day.start(in: calendar).addingTimeInterval(12 * 3600).formatted(style.locale(calendar.locale ?? .autoupdatingCurrent))
    }
}

private extension String {
    /// "Due today", but "Due Friday".
    var lowercasedIfRelative: String {
        ["Today", "Tomorrow", "Yesterday"].contains(self) ? lowercased() : self
    }
}
