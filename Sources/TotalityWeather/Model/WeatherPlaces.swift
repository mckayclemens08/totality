import Foundation
import TotalityCore

/// A place saved in Weather: a city found by search, with where it is.
public struct WeatherPlace: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Such as "Provo".
    public var name: String
    /// Such as "Utah, United States".
    public var region: String
    public var coordinate: Coordinate
    /// The place's own time zone, when the search gave one.
    public var timeZone: String?

    public init(id: UUID = UUID(), name: String, region: String, coordinate: Coordinate, timeZone: String? = nil) {
        self.id = id
        self.name = name
        self.region = region
        self.coordinate = coordinate
        self.timeZone = timeZone
    }
}

/// The person's saved places, in their order, as one sealed record that syncs (issue 203). Each place keeps
/// when it last changed, and a removed place stays as a marker with no place, so two devices' lists come
/// together by keeping the later of each, whichever way round.
public struct WeatherPlaces: MergedRecord {
    public struct Entry: Codable, Equatable, Sendable {
        /// Nil once removed.
        public var place: WeatherPlace?
        public var order: Double
        public var changedAt: Date
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// The places still saved, in the person's order.
    public var places: [WeatherPlace] {
        let kept: [(order: Double, place: WeatherPlace)] = entries.values.compactMap { entry in
            guard let place = entry.place else { return nil }
            return (entry.order, place)
        }
        let sorted = kept.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.place.id.uuidString < b.place.id.uuidString
        }
        return sorted.map(\.place)
    }

    /// Adds a place at the end. The same spot again, to two decimal places, isn't added twice.
    @discardableResult
    public mutating func add(_ place: WeatherPlace, at date: Date) -> WeatherPlace {
        if let same = places.first(where: { $0.coordinate.rough == place.coordinate.rough }) { return same }
        let last = entries.values.filter { $0.place != nil }.map(\.order).max() ?? 0
        entries[place.id.uuidString] = Entry(place: place, order: last + 1, changedAt: date)
        return place
    }

    public mutating func remove(_ id: UUID, at date: Date) {
        guard let entry = entries[id.uuidString], entry.place != nil else { return }
        entries[id.uuidString] = Entry(place: nil, order: entry.order, changedAt: date)
    }

    /// Puts the places in this order. Any not named keep their place after them.
    public mutating func reorder(_ ids: [UUID], at date: Date) {
        for (index, id) in ids.enumerated() {
            guard var entry = entries[id.uuidString], entry.place != nil, entry.order != Double(index + 1) else { continue }
            entry.order = Double(index + 1)
            entry.changedAt = date
            entries[id.uuidString] = entry
        }
    }

    public static func merged(_ one: WeatherPlaces, _ other: WeatherPlaces) -> WeatherPlaces {
        WeatherPlaces(entries: one.entries.merging(other.entries) { Self.later($0, $1) })
    }

    /// The later change. A tie goes the same way whichever way round: a removal wins, then the larger order.
    static func later(_ a: Entry, _ b: Entry) -> Entry {
        if a.changedAt != b.changedAt { return a.changedAt > b.changedAt ? a : b }
        if (a.place == nil) != (b.place == nil) { return a.place == nil ? a : b }
        if a.order != b.order { return a.order > b.order ? a : b }
        let left = (try? JSONEncoder.sorted.encode(a)) ?? Data(), right = (try? JSONEncoder.sorted.encode(b)) ?? Data()
        return left.lexicographicallyPrecedes(right) ? b : a
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
