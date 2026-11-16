import Foundation

/// What quick add understood in what was typed. Parsed on the device: nothing typed leaves it.
public struct ParsedTask: Equatable, Sendable {
    public enum Part: String, Sendable, Equatable {
        case when, time, deadline, tag, priority, place
    }

    /// One understood piece, where it sits in what was typed, so it can be highlighted.
    public struct Piece: Equatable, Sendable {
        public let range: Range<String.Index>
        public let part: Part
    }

    public var title: String = ""
    public var when: TaskDay?
    public var isEvening = false
    public var time: TaskTime?
    public var deadline: TaskDay?
    public var tags: [String] = []
    public var priority: TaskItem.Priority = .none
    public var place: TaskItem.Place?
    public var pieces: [Piece] = []

    public init() {}

    /// The task this makes, landing in `defaultPlace` when nothing typed said where.
    public func task(defaultPlace: TaskItem.Place, defaultWhen: TaskDay?, order: Double, now: Date) -> TaskItem {
        let place = place ?? defaultPlace
        let when = when ?? (place == .someday ? nil : defaultWhen)
        return TaskItem(
            title: title, place: when == nil ? place : (place == .inbox ? .anytime : place), when: when,
            isEvening: when == nil ? false : isEvening, time: when == nil ? nil : time, deadline: deadline,
            tags: tags, priority: priority, order: order, createdAt: now
        )
    }
}

/// Reads dates, times, tags, priority and places out of a line typed in English, like
/// "Email Dr. Lee about thesis chapter 2 tomorrow 9am #school !high". Words it doesn't understand stay in
/// the title. Each kind of thing is read once: a second date stays in the title as typed.
public enum QuickAddParser {
    public static func parse(_ text: String, now: Date, calendar: Calendar) -> ParsedTask {
        let words = Word.split(text)
        var reader = Reader(words: words, today: TaskDay(now, in: calendar), calendar: calendar)
        reader.run()
        var parsed = reader.result
        parsed.pieces.sort { $0.range.lowerBound < $1.range.lowerBound }
        parsed.title = title(of: text, without: parsed.pieces.map(\.range))
        // A time with nothing to say which day goes on the deadline's day, or else today.
        if parsed.time != nil, parsed.when == nil, parsed.place != .someday {
            parsed.when = parsed.deadline ?? reader.today
        }
        if parsed.isEvening, parsed.when == nil { parsed.when = reader.today }
        if parsed.when != nil, parsed.place == .someday { parsed.place = nil }
        return parsed
    }

    /// Several tasks at once, one per line, as when a list is pasted.
    public static func parseLines(_ text: String, now: Date, calendar: Calendar) -> [ParsedTask] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let cleaned = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^([-*•]\s*(\[[ xX]\]\s*)?|\d+[.)]\s*)"#, with: "", options: .regularExpression)
            guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return parse(cleaned, now: now, calendar: calendar)
        }
    }

    /// What's left once the understood pieces are taken out, tidied.
    static func title(of text: String, without ranges: [Range<String.Index>]) -> String {
        var kept = ""
        var index = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= index {
            kept += text[index..<range.lowerBound]
            kept += " "
            index = range.upperBound
        }
        kept += text[index...]
        let words = kept.split(whereSeparator: \.isWhitespace).map(String.init)
        var tidy: [String] = []
        for word in words {
            // A comma or full stop left alone where a piece was taken out goes with it.
            if [",", ".", ";", "-", "–"].contains(word) { continue }
            tidy.append(word)
        }
        var title = tidy.joined(separator: " ")
        while let last = title.last, [",", ";", "-", "–"].contains(last) { title.removeLast() }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

/// One word as typed, and the same word folded for matching.
struct Word {
    let range: Range<String.Index>
    let folded: String

    static func split(_ text: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begun = start { words.append(make(text, begun..<index)) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let begun = start { words.append(make(text, begun..<text.endIndex)) }
        return words
    }

    private static func make(_ text: String, _ range: Range<String.Index>) -> Word {
        var folded = text[range].lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        // Trailing punctuation is part of the piece but not of what's matched.
        while let last = folded.last, [",", ".", ";", ":", "!", "?", ")"].contains(last), folded.count > 1 {
            if last == "!" && folded.hasPrefix("!") { break }
            folded.removeLast()
        }
        return Word(range: range, folded: folded)
    }
}

private struct Reader {
    let words: [Word]
    let today: TaskDay
    let calendar: Calendar
    var result = ParsedTask()
    private var index = 0

    init(words: [Word], today: TaskDay, calendar: Calendar) {
        self.words = words
        self.today = today
        self.calendar = calendar
    }

    mutating func run() {
        while index < words.count {
            if let used = step() {
                index += used
            } else {
                index += 1
            }
        }
    }

    private func word(_ offset: Int) -> String? {
        let at = index + offset
        return at < words.count ? words[at].folded : nil
    }

    private mutating func mark(_ count: Int, as part: ParsedTask.Part, from offset: Int = 0) {
        let first = words[index + offset].range.lowerBound
        let last = words[index + offset + count - 1].range.upperBound
        result.pieces.append(.init(range: first..<last, part: part))
    }

    /// How many words were used, or nil when nothing starts here.
    private mutating func step() -> Int? {
        guard let first = word(0) else { return nil }

        // Repeats come in a later step, so "every Monday" stays as typed rather than becoming one date.
        if first == "every" || first == "each" { return 2 }

        if first.hasPrefix("#"), result.tags.count < 20 {
            let tag = String(first.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber || "-_/".contains($0) }) {
                if !result.tags.contains(tag) { result.tags.append(tag) }
                mark(1, as: .tag)
                return 1
            }
        }

        if first.hasPrefix("!"), result.priority == .none, let priority = Self.priorities[first] {
            result.priority = priority
            mark(1, as: .priority)
            return 1
        }

        if result.place == nil, result.when == nil, first == "someday" || first == "anytime" {
            result.place = first == "someday" ? .someday : .anytime
            mark(1, as: .place)
            return 1
        }

        if result.deadline == nil, ["due", "by", "deadline"].contains(first),
           let (day, used, _) = date(at: 1, loose: true) {
            result.deadline = day
            mark(1 + used, as: .deadline)
            return 1 + used
        }

        if result.when == nil, let (day, used, evening) = date(at: 0, loose: false) {
            result.when = day
            if evening { result.isEvening = true }
            mark(used, as: .when)
            return used
        }

        if result.time == nil, let (time, used) = time(at: 0) {
            result.time = time
            mark(used, as: .time)
            return used
        }
        return nil
    }

    static let priorities: [String: TaskItem.Priority] = [
        "!high": .high, "!h": .high, "!3": .high, "!!!": .high,
        "!medium": .medium, "!med": .medium, "!m": .medium, "!2": .medium, "!!": .medium,
        "!low": .low, "!l": .low, "!1": .low,
    ]

    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]
    /// Short names read as days only after a word like "on" or "next", so "sat with Gran" stays a title.
    static let shortWeekdays: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7,
    ]
    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]
    static let counts: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10,
    ]

    /// A day starting `offset` words in: the day, how many words it took, and whether it said evening.
    private func date(at offset: Int, loose: Bool) -> (TaskDay, Int, Bool)? {
        guard let first = word(offset) else { return nil }
        // "on Friday", "on Nov 20"
        if first == "on", let (day, used, evening) = date(at: offset + 1, loose: true) {
            return (day, used + 1, evening)
        }
        if let (day, used) = plainDate(at: offset, loose: loose) {
            // "tomorrow evening", "Friday night"
            if let next = word(offset + used), next == "evening" || next == "night" {
                return (day, used + 1, true)
            }
            return (day, used, false)
        }
        if first == "tonight" { return (today, 1, true) }
        if first == "this", word(offset + 1) == "evening" { return (today, 2, true) }
        return nil
    }

    private func plainDate(at offset: Int, loose: Bool) -> (TaskDay, Int)? {
        guard let first = word(offset) else { return nil }
        switch first {
        case "today", "tod": return (today, 1)
        case "tomorrow", "tmr", "tmrw", "tomorow", "tommorow": return (today.adding(days: 1, in: calendar), 1)
        default: break
        }
        if first == "day", word(offset + 1) == "after", word(offset + 2) == "tomorrow" {
            return (today.adding(days: 2, in: calendar), 3)
        }
        if let weekday = Self.weekdays[first] ?? (loose ? Self.shortWeekdays[first] : nil) {
            return (nearest(weekday, includingToday: false), 1)
        }
        if first == "this" || first == "next", let second = word(offset + 1) {
            if let weekday = Self.weekdays[second] ?? Self.shortWeekdays[second] {
                if first == "this" { return (nearest(weekday, includingToday: true), 2) }
                let soonest = nearest(weekday, includingToday: false)
                return (sameWeek(soonest, today) ? soonest.adding(days: 7, in: calendar) : soonest, 2)
            }
            if second == "week" || second == "wk" {
                guard first == "next" else { return nil }
                return (startOfNextWeek(), 2)
            }
            if second == "month", first == "next" {
                let start = calendar.date(from: DateComponents(year: today.year, month: today.month + 1, day: 1, hour: 12))
                return start.map { (TaskDay($0, in: calendar), 2) }
            }
            if second == "weekend" { return (nearest(7, includingToday: true), 2) }
        }
        if first == "weekend" && loose { return (nearest(7, includingToday: true), 1) }
        // "in 3 days", "in a week", "in two weeks"
        if first == "in", let amount = word(offset + 1).flatMap({ Int($0) ?? Self.counts[$0] }), amount > 0, amount < 1000,
           let unit = word(offset + 2) {
            switch unit {
            case "day", "days": return (today.adding(days: amount, in: calendar), 3)
            case "week", "weeks", "wk", "wks": return (today.adding(days: amount * 7, in: calendar), 3)
            case "month", "months":
                let noon = today.start(in: calendar).addingTimeInterval(12 * 3600)
                return calendar.date(byAdding: .month, value: amount, to: noon).map { (TaskDay($0, in: calendar), 3) }
            default: break
            }
        }
        // "Nov 20", "November 20th", "Nov 20 2027"
        if let month = Self.months[first], let dayNumber = word(offset + 1).flatMap(Self.dayNumber) {
            if let year = word(offset + 2).flatMap(Self.year), let day = valid(year, month, dayNumber) { return (day, 3) }
            return upcoming(month, dayNumber).map { ($0, 2) }
        }
        // "20 Nov", "20th November"
        if let dayNumber = Self.dayNumber(first), let month = word(offset + 1).flatMap({ Self.months[$0] }) {
            if let year = word(offset + 2).flatMap(Self.year), let day = valid(year, month, dayNumber) { return (day, 3) }
            return upcoming(month, dayNumber).map { ($0, 2) }
        }
        // "2026-11-20"
        let iso = first.split(separator: "-").compactMap { Int($0) }
        if iso.count == 3, first.count == 10, let day = valid(iso[0], iso[1], iso[2]) { return (day, 1) }
        // "11/20" or "11/20/2027", in the order the person's region writes them
        let slashed = first.split(separator: "/", omittingEmptySubsequences: false)
        if slashed.count == 2 || slashed.count == 3, slashed.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let numbers = slashed.compactMap { Int($0) }
            let (month, dayNumber) = monthFirst ? (numbers[0], numbers[1]) : (numbers[1], numbers[0])
            if numbers.count == 3 {
                let year = numbers[2] < 100 ? 2000 + numbers[2] : numbers[2]
                return valid(year, month, dayNumber).map { ($0, 1) }
            }
            return upcoming(month, dayNumber).map { ($0, 1) }
        }
        return nil
    }

    /// Whether this person's region writes the month before the day.
    private var monthFirst: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: calendar.locale ?? .current) ?? "M/d"
        guard let m = format.firstIndex(of: "M"), let d = format.firstIndex(of: "d") else { return true }
        return m < d
    }

    private static func dayNumber(_ word: String) -> Int? {
        var digits = word
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
            digits.removeLast(suffix.count)
        }
        guard let number = Int(digits), (1...31).contains(number), digits.count <= 2 else { return nil }
        return number
    }

    private static func year(_ word: String) -> Int? {
        guard word.count == 4, let number = Int(word), (2000...2200).contains(number) else { return nil }
        return number
    }

    private func valid(_ year: Int, _ month: Int, _ day: Int) -> TaskDay? {
        guard (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        else { return nil }
        let found = TaskDay(date, in: calendar)
        return found == TaskDay(year: year, month: month, day: day) ? found : nil
    }

    /// This year's, or next year's once this year's has passed.
    private func upcoming(_ month: Int, _ day: Int) -> TaskDay? {
        if let this = valid(today.year, month, day), this >= today { return this }
        return valid(today.year + 1, month, day)
    }

    private func nearest(_ weekday: Int, includingToday: Bool) -> TaskDay {
        let current = today.weekday(in: calendar)
        var ahead = (weekday - current + 7) % 7
        if ahead == 0 && !includingToday { ahead = 7 }
        return today.adding(days: ahead, in: calendar)
    }

    private func sameWeek(_ a: TaskDay, _ b: TaskDay) -> Bool {
        let first = calendar.firstWeekday
        func weekStart(_ day: TaskDay) -> TaskDay {
            day.adding(days: -((day.weekday(in: calendar) - first + 7) % 7), in: calendar)
        }
        return weekStart(a) == weekStart(b)
    }

    private func startOfNextWeek() -> TaskDay {
        let back = (today.weekday(in: calendar) - calendar.firstWeekday + 7) % 7
        return today.adding(days: 7 - back, in: calendar)
    }

    /// A time starting `offset` words in, and how many words it took.
    private func time(at offset: Int) -> (TaskTime, Int)? {
        guard let first = word(offset) else { return nil }
        if first == "at" || first == "@" {
            guard let next = word(offset + 1) else { return nil }
            if let (time, used) = clock(at: offset + 1) { return (time, used + 1) }
            // "at 9" on its own: the likelier half of the day.
            if let hour = Int(next), (0...23).contains(hour), next.count <= 2 {
                let adjusted = (1...6).contains(hour) ? hour + 12 : hour
                return TaskTime(hour: adjusted).map { ($0, 2) }
            }
            return nil
        }
        return clock(at: offset)
    }

    /// "9am", "9:30 pm", "14:00", "noon".
    private func clock(at offset: Int) -> (TaskTime, Int)? {
        guard let first = word(offset) else { return nil }
        if first == "noon" || first == "midday" { return (.noon, 1) }
        var text = first
        var used = 1
        var half: String?
        for suffix in ["am", "pm", "a.m", "p.m", "a", "p"] where text.hasSuffix(suffix) && text.count > suffix.count {
            let rest = text.dropLast(suffix.count)
            if rest.last?.isNumber == true {
                half = suffix.hasPrefix("a") ? "am" : "pm"
                text = String(rest)
                break
            }
        }
        if half == nil, let next = word(offset + 1), ["am", "pm", "a.m", "p.m"].contains(next) {
            half = next.hasPrefix("a") ? "am" : "pm"
            used = 2
        }
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "." })
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts[0].count <= 2, parts.count == 1 || parts[1].count == 2,
              var hour = Int(parts[0]), let minute = parts.count == 2 ? Int(parts[1]) : 0
        else { return nil }
        if let half {
            guard (1...12).contains(hour) else { return nil }
            if half == "pm" && hour != 12 { hour += 12 }
            if half == "am" && hour == 12 { hour = 0 }
        } else if parts.count == 1 || text.contains(".") {
            // A bare number, or one like 3.14, is a number, not a time.
            return nil
        }
        return TaskTime(hour: hour, minute: minute).map { ($0, used) }
    }
}
