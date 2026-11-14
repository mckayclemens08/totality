import Foundation

/// A daily word goal and how many words were written today, across every doc, on this device. It holds
/// only numbers and a date, never any words, so it lives in the device's settings and isn't synced.
struct WritingGoals: Equatable {
    static let targetKey = "reader.writing.dailyTarget"
    static let todayKey = "reader.writing.today"

    var dailyTarget: Int
    var day: String
    var written: Int

    /// The calendar day a count belongs to, in the person's own time zone.
    static func day(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func load(from defaults: UserDefaults = .standard, now: Date = Date()) -> WritingGoals {
        let today = day(of: now)
        let stored = (defaults.string(forKey: todayKey) ?? "").split(separator: "|")
        let written = stored.count == 2 && stored[0] == today ? Int(stored[1]) ?? 0 : 0
        return WritingGoals(dailyTarget: max(0, defaults.integer(forKey: targetKey)), day: today, written: max(0, written))
    }

    /// Adds words just written. A new day starts again from zero.
    mutating func add(_ words: Int, now: Date = Date()) {
        let today = Self.day(of: now)
        if today != day {
            day = today
            written = 0
        }
        written += max(0, words)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(dailyTarget, forKey: Self.targetKey)
        defaults.set("\(day)|\(written)", forKey: Self.todayKey)
    }

    /// How far along a target is, from 0 to 1. Nil when there's no target.
    static func progress(_ count: Int, of target: Int?) -> Double? {
        guard let target, target > 0 else { return nil }
        return min(1, Double(count) / Double(target))
    }
}
