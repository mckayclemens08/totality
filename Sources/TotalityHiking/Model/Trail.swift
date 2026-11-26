import Foundation

/// How hard a trail is (issue 240, section 4).
public enum Difficulty: String, Codable, Sendable, CaseIterable {
    case easy, moderate, hard

    public var name: String {
        switch self {
        case .easy: "Easy"
        case .moderate: "Moderate"
        case .hard: "Hard"
        }
    }

    /// From OpenStreetMap's `sac_scale` when the trail has one: "hiking" is easy, "mountain_hiking" is
    /// moderate, and anything harder is hard.
    public init?(sacScale: String?) {
        switch sacScale {
        case "hiking": self = .easy
        case "mountain_hiking": self = .moderate
        case "demanding_mountain_hiking", "alpine_hiking", "demanding_alpine_hiking", "difficult_alpine_hiking": self = .hard
        default: return nil
        }
    }

    /// The Shenandoah rating, √(climb in feet × 2 × miles): under 50 is easy, up to 100 moderate, more is hard.
    /// With no climb known, it goes by length alone.
    public init(metres: Double, climb: Double?) {
        if let climb {
            let rating = (climb * 3.28084 * 2 * (metres / 1609.344)).squareRoot()
            self = rating < 50 ? .easy : rating <= 100 ? .moderate : .hard
        } else {
            self = metres < 5000 ? .easy : metres < 12000 ? .moderate : .hard
        }
    }
}

/// A trail from OpenStreetMap: its name, its route as one or more lines, and what's known about it.
public struct Trail: Codable, Hashable, Sendable, Identifiable {
    /// OpenStreetMap's own name for it, like "relation/123" or "way/456", or the first way's when several
    /// ways with the same name make one trail.
    public var id: String
    public var name: String
    /// Each piece of the route. A trail made of several ways has several.
    public var lines: [[GeoPoint]]
    public var sacScale: String?
    public var surface: String?
    /// "Path", "Footway", "Track", or "Hiking route" for a route relation.
    public var kind: String
    /// Heights along the trail from the elevation model, start to end, once looked up.
    public var profile: [Double]?
    /// When it was saved for offline use, or nil if it isn't saved.
    public var savedAt: Date?
    /// The group it is saved in, or nil for none. A trail is in one group at most.
    public var groupID: UUID?

    public init(
        id: String, name: String, lines: [[GeoPoint]], sacScale: String? = nil, surface: String? = nil,
        kind: String = "Path", profile: [Double]? = nil, savedAt: Date? = nil, groupID: UUID? = nil
    ) {
        self.groupID = groupID
        self.id = id
        self.name = name
        self.lines = lines
        self.sacScale = sacScale
        self.surface = surface
        self.kind = kind
        self.profile = profile
        self.savedAt = savedAt
    }

    public var metres: Double { lines.reduce(0) { $0 + GeoLine.length($1) } }
    public var climb: Double? { profile.map { GeoLine.climb($0, threshold: 5) } }
    public var highest: Double? { profile?.max() }
    public var lowest: Double? { profile?.min() }
    public var difficulty: Difficulty { Difficulty(sacScale: sacScale) ?? Difficulty(metres: metres, climb: climb) }

    /// Every point, in order, for the map and the elevation lookup.
    public var points: [GeoPoint] { lines.flatMap { $0 } }

    /// The point nearest to `here`, in metres, for "2.4 km away".
    public func distance(from here: GeoPoint) -> Double {
        points.map { $0.distance(to: here) }.min() ?? .infinity
    }

    /// A link to the trail on openstreetmap.org, for its credit line.
    public var sourceURL: URL? { isImported ? nil : URL(string: "https://www.openstreetmap.org/\(id)") }

    /// The ID prefix of a trail brought in from a GPX file, which has no OpenStreetMap page.
    public static let importedPrefix = "gpx/"
    public var isImported: Bool { id.hasPrefix(Self.importedPrefix) }
}

/// A named group of saved trails (owner, 2026-11-26). A trail is in one group or none, and "All saved" shows
/// every trail regardless.
public struct HikeGroup: Codable, Hashable, Sendable, Identifiable {
    public static let maxNameLength = 40
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// A name trimmed and cut to 40 characters, or nil if nothing is left.
    public static func clean(_ name: String) -> String? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The trails found near a rough location, as kept sealed on the iPhone so Hiking opens at once.
public struct NearbyTrails: Codable, Equatable, Sendable {
    public var around: GeoPoint
    public var fetchedAt: Date
    public var trails: [Trail]

    public init(around: GeoPoint, fetchedAt: Date, trails: [Trail]) {
        self.around = around
        self.fetchedAt = fetchedAt
        self.trails = trails
    }

    /// Fresh for a day, and only near where it was found.
    public func isFresh(at now: Date, near here: GeoPoint) -> Bool {
        now.timeIntervalSince(fetchedAt) < 24 * 3600 && around.distance(to: here.rough) < 2000
    }
}
