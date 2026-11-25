import Foundation
import TotalityCore

/// A city on the world clock. Daylight saving comes from the device's own time zone data, offline.
public struct WorldCity: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// An IANA time zone, like "America/Phoenix".
    public var timeZoneID: String
    public var order: Double
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, timeZoneID: String, order: Double, updatedAt: Date) {
        self.id = id
        self.name = name
        self.timeZoneID = timeZoneID
        self.order = order
        self.updatedAt = updatedAt
    }

    public var timeZone: TimeZone? { TimeZone(identifier: timeZoneID) }
}

/// A timer someone named, like "Tea, 3 min", that starts from one press.
public struct TimerPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var seconds: Int
    public var order: Double
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, seconds: Int, order: Double, updatedAt: Date) {
        self.id = id
        self.name = name
        self.seconds = seconds
        self.order = order
        self.updatedAt = updatedAt
    }
}

/// The stopwatch, kept as when it started and what it had before, so it keeps counting with the app
/// closed and on another device.
public struct Stopwatch: Codable, Hashable, Sendable {
    /// When the current run started. Nil while stopped.
    public var startedAt: Date?
    /// Time counted before `startedAt`.
    public var banked: TimeInterval
    /// Each lap's own length, first lap first.
    public var laps: [TimeInterval]
    public var updatedAt: Date

    public init(startedAt: Date? = nil, banked: TimeInterval = 0, laps: [TimeInterval] = [], updatedAt: Date = .distantPast) {
        self.startedAt = startedAt
        self.banked = banked
        self.laps = laps
        self.updatedAt = updatedAt
    }

    public var isRunning: Bool { startedAt != nil }
    /// At 00:00.00 and stopped: ready, not empty.
    public var isReset: Bool { startedAt == nil && banked == 0 && laps.isEmpty }

    public func elapsed(at now: Date) -> TimeInterval {
        banked + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// The lap still running.
    public func currentLap(at now: Date) -> TimeInterval {
        max(0, elapsed(at: now) - laps.reduce(0, +))
    }

    public mutating func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
        updatedAt = now
    }

    public mutating func stop(at now: Date) {
        guard startedAt != nil else { return }
        banked = elapsed(at: now)
        startedAt = nil
        updatedAt = now
    }

    public mutating func lap(at now: Date) {
        guard startedAt != nil else { return }
        laps.append(currentLap(at: now))
        updatedAt = now
    }

    public mutating func reset(at now: Date) {
        self = Stopwatch(updatedAt: now)
    }

    /// The fastest and slowest laps' places, once there are two to compare.
    public var fastestLap: Int? {
        guard laps.count >= 2 else { return nil }
        return laps.indices.min { laps[$0] < laps[$1] }
    }

    public var slowestLap: Int? {
        guard laps.count >= 2 else { return nil }
        return laps.indices.max { laps[$0] < laps[$1] }
    }
}

/// The Clock's record that syncs: world cities, timer presets and the stopwatch (issue 204, question 2).
/// Alarms aren't here; each rings on the device that set it.
///
/// Every item carries when it last changed, and a removal is kept with its time, so two devices' copies
/// come together by keeping the later of each.
public struct ClockItems: Codable, Equatable, Sendable {
    public var cities: [WorldCity]
    public var presets: [TimerPreset]
    public var stopwatch: Stopwatch
    /// Removed cities and presets, by ID, with when.
    public var removed: [UUID: Date]

    public init(cities: [WorldCity] = [], presets: [TimerPreset] = [], stopwatch: Stopwatch = Stopwatch(), removed: [UUID: Date] = [:]) {
        self.cities = cities
        self.presets = presets
        self.stopwatch = stopwatch
        self.removed = removed
    }

    /// A new person's presets, as the mockup draws them.
    public static func starting(at now: Date) -> ClockItems {
        ClockItems(presets: [
            TimerPreset(name: "Tea", seconds: 180, order: 1, updatedAt: now),
            TimerPreset(name: "Eggs", seconds: 420, order: 2, updatedAt: now),
            TimerPreset(name: "Focus", seconds: 1500, order: 3, updatedAt: now),
        ])
    }

    public var shownCities: [WorldCity] {
        cities.filter { isKept($0.id, $0.updatedAt) }.sorted { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }
    }

    public var shownPresets: [TimerPreset] {
        presets.filter { isKept($0.id, $0.updatedAt) }.sorted { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }
    }

    private func isKept(_ id: UUID, _ updated: Date) -> Bool {
        guard let gone = removed[id] else { return true }
        return updated > gone
    }

    public mutating func remove(_ id: UUID, at now: Date) {
        removed[id] = max(removed[id] ?? .distantPast, now)
    }
}

extension ClockItems: MergedRecord {
    public static func merged(_ one: ClockItems, _ other: ClockItems) -> ClockItems {
        ClockItems(
            cities: LaterWins.merge(one.cities, other.cities, updated: \.updatedAt),
            presets: LaterWins.merge(one.presets, other.presets, updated: \.updatedAt),
            stopwatch: LaterWins.pick(one.stopwatch, other.stopwatch, updated: \.updatedAt),
            removed: one.removed.merging(other.removed, uniquingKeysWith: { max($0, $1) })
        )
    }
}

/// Keeps the later of two copies, and on a tie the one whose encoding sorts last, so a merge gives the
/// same answer whichever way round.
enum LaterWins {
    static func pick<T: Codable>(_ one: T, _ other: T, updated: KeyPath<T, Date>) -> T {
        if one[keyPath: updated] != other[keyPath: updated] {
            return one[keyPath: updated] > other[keyPath: updated] ? one : other
        }
        return tieKey(one) >= tieKey(other) ? one : other
    }

    static func merge<T: Codable & Identifiable>(_ one: [T], _ other: [T], updated: KeyPath<T, Date>) -> [T] where T.ID == UUID {
        var byID: [UUID: T] = [:]
        for item in one + other {
            byID[item.id] = byID[item.id].map { pick($0, item, updated: updated) } ?? item
        }
        return byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func tieKey<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
