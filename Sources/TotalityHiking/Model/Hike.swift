import Foundation
import TotalityCore

/// One hike recorded on this iPhone. Sealed with the content key and never uploaded in v1 (issue 240).
public struct Hike: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    /// Time spent moving, leaving out pauses.
    public var seconds: TimeInterval
    /// Each stretch between pauses, as points about 5 m or more apart.
    public var segments: [[GeoPoint]]
    /// The OpenStreetMap trail it was started from, if any.
    public var trailID: String?

    public init(
        id: UUID = UUID(), title: String, startedAt: Date, endedAt: Date, seconds: TimeInterval,
        segments: [[GeoPoint]], trailID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.seconds = seconds
        self.segments = segments
        self.trailID = trailID
    }

    public var points: [GeoPoint] { segments.flatMap { $0 } }
    public var metres: Double { segments.reduce(0) { $0 + GeoLine.length($1) } }
    public var climb: Double { segments.reduce(0) { $0 + GeoLine.climb($1.compactMap(\.elevation)) } }
    public var highest: Double? { points.compactMap(\.elevation).max() }

    /// How the hike is named in a `ContentRef`, which is how another module hears of it.
    public var ref: ContentRef {
        ContentRef(module: .hiking, kind: .hike, id: id, keyRef: .crk(objectID: id), preview: .init(title: title))
    }

    /// What a Social post about the hike says, before the person changes it.
    public func postBody(units: HikeUnits) -> String {
        "\(units.distance(metres)) · \(units.climb(climb)) · \(HikeUnits.shortDuration(seconds)). #hiking"
    }
}

/// Builds a hike from the iPhone's location fixes while recording. Fixes vaguer than 30 m are dropped, and a
/// fix less than 5 m from the last one is skipped, so standing still adds nothing.
public struct TrackBuilder: Sendable, Equatable {
    public static let worstAccuracy = 30.0
    public static let spacing = 5.0

    public private(set) var segments: [[GeoPoint]] = [[]]
    public private(set) var movingSeconds: TimeInterval = 0
    public private(set) var isPaused = false
    private var lastTime: Date?
    public private(set) var lastFix: GeoPoint?

    public init() {}

    /// Takes one fix. Returns whether it was kept.
    @discardableResult
    public mutating func add(_ point: GeoPoint, accuracy: Double, at time: Date) -> Bool {
        guard !isPaused, accuracy >= 0, accuracy <= Self.worstAccuracy, point.isValid else { return false }
        if let lastTime { movingSeconds += max(0, min(time.timeIntervalSince(lastTime), 60)) }
        lastTime = time
        lastFix = point
        if let previous = segments[segments.count - 1].last, previous.distance(to: point) < Self.spacing { return false }
        segments[segments.count - 1].append(point)
        return true
    }

    public mutating func pause() {
        isPaused = true
        lastTime = nil
    }

    /// Carries on in a new stretch, so the line doesn't jump across where the person went while paused.
    public mutating func resume() {
        guard isPaused else { return }
        isPaused = false
        if !(segments.last?.isEmpty ?? true) { segments.append([]) }
    }

    public var kept: [[GeoPoint]] { segments.filter { $0.count > 1 } }
    public var metres: Double { kept.reduce(0) { $0 + GeoLine.length($1) } }
    public var climb: Double { kept.reduce(0) { $0 + GeoLine.climb($1.compactMap(\.elevation)) } }
}
