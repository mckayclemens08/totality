import Foundation

/// Where the person stopped in a Reader file, so it opens there on any of their devices.
public struct ReadingPlace: Codable, Equatable, Sendable {
    public enum Spot: Codable, Equatable, Sendable {
        /// A PDF's page, counted from zero.
        case pdf(page: Int)
        /// An EPUB or HTML file: the chapter's path and how far through it, from 0 to 1.
        case book(chapter: String, progress: Double)
        /// A doc: how far down, from 0 to 1, and where the cursor was in its text.
        case doc(scroll: Double, cursor: Int)
    }

    public var spot: Spot
    /// Where Listen was in the item's text, when it had been playing.
    public var listen: Int?
    public var at: Date

    public init(spot: Spot, listen: Int? = nil, at: Date) {
        self.spot = spot
        self.listen = listen
        self.at = at
    }
}

/// Every reading place of one person, as one record. It's sealed and synced as a single object, so the
/// server learns only that the record changed, never which item was opened or when.
public struct ReadingPlaces: Codable, Equatable, Sendable {
    public var places: [UUID: ReadingPlace] = [:]
    /// When an item's place was dropped because the item was deleted, so an older copy can't bring it back.
    public var removed: [UUID: Date] = [:]

    /// The most removals remembered. Older ones are long since everywhere.
    static let mostRemoved = 500

    public init(places: [UUID: ReadingPlace] = [:], removed: [UUID: Date] = [:]) {
        self.places = places
        self.removed = removed
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        places = try values.decodeIfPresent([UUID: ReadingPlace].self, forKey: .places) ?? [:]
        removed = try values.decodeIfPresent([UUID: Date].self, forKey: .removed) ?? [:]
    }

    /// Two devices' copies as one: the newest place for each item, minus items deleted after it was set.
    public static func merged(_ one: ReadingPlaces, _ other: ReadingPlaces) -> ReadingPlaces {
        ReadingPlaces(
            places: one.places.merging(other.places, uniquingKeysWith: newer),
            removed: one.removed.merging(other.removed, uniquingKeysWith: max)
        ).normalized()
    }

    /// The later of two places. Two set at the same moment are told apart by what they hold, so a merge
    /// gives the same answer whichever way round it's done.
    private static func newer(_ one: ReadingPlace, _ other: ReadingPlace) -> ReadingPlace {
        if one.at != other.at { return one.at > other.at ? one : other }
        return String(describing: one) >= String(describing: other) ? one : other
    }

    func normalized() -> ReadingPlaces {
        let kept = places.filter { id, place in removed[id].map { $0 < place.at } ?? true }
        let latest = removed.sorted { ($0.value, $0.key.uuidString) > ($1.value, $1.key.uuidString) }.prefix(Self.mostRemoved)
        return ReadingPlaces(places: kept, removed: Dictionary(uniqueKeysWithValues: latest.map { ($0.key, $0.value) }))
    }

    /// Records a place, unless a newer one is already here.
    mutating func set(_ place: ReadingPlace, for id: UUID) {
        if let kept = places[id], kept.at > place.at { return }
        places[id] = place
        removed[id] = nil
    }

    /// Drops the places of items that no longer exist, remembering when, so other devices drop them too.
    mutating func prune(keeping ids: Set<UUID>, at date: Date) {
        for id in places.keys where !ids.contains(id) {
            places[id] = nil
            removed[id] = date
        }
        self = normalized()
    }

    /// Where to open an item. When Read along is on and Listen got further than the reading did, Listen's
    /// place wins, so the page opens on what was last heard.
    public func opening(_ id: UUID, listenOffset: Int?, readAlong: Bool, readingOffset: Int?) -> Opening? {
        let place = places[id]
        if readAlong, let listenOffset, listenOffset > (readingOffset ?? place?.listen ?? -1) {
            return .listen(listenOffset)
        }
        return place.map { .spot($0.spot) }
    }

    public enum Opening: Equatable {
        case spot(ReadingPlace.Spot)
        /// Open where this place in Listen's text is.
        case listen(Int)
    }
}
