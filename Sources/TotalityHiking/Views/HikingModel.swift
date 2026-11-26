import Foundation
import Observation
import TotalityCore

/// Hiking's state for its screens and its home tile (issue 240). What's saved opens at once from the sealed
/// log; trails nearby come from OpenStreetMap only when the person opens Nearby or pulls to refresh.
@MainActor
@Observable
public final class HikingModel {
    public enum Phase: Equatable { case loading, ready, failed }

    /// Where the Nearby list stands.
    public enum NearbyState: Equatable {
        case idle, loading, ready, offline, failed
        /// Location is off for Totality. Saved trails and recording still need it, so the screen says how.
        case noLocation
    }

    /// A hike being recorded.
    public struct Recording: Equatable {
        public var startedAt: Date
        public var trail: Trail?
        public var track = TrackBuilder()
        public var title: String { trail?.name ?? "Hike" }
    }

    public private(set) var phase = Phase.loading
    public private(set) var nearby: [Trail] = []
    public private(set) var nearbyState = NearbyState.idle
    public private(set) var saved: [Trail] = []
    public private(set) var hikes: [Hike] = []
    public private(set) var here: GeoPoint?
    public private(set) var recording: Recording?
    /// A hike deleted in the last few seconds, which Undo brings back.
    public private(set) var recentlyDeleted: Hike?
    public var notice: String?
    /// Something asked for from search: a hike's UUID or a trail's OpenStreetMap ID.
    public var requestedItem: String?
    public var units: HikeUnits
    /// Starts a Social post through the app, which hands it to Social's composer. Nothing posts from here.
    public var onShare: (@MainActor (PostDraft) -> Void)?

    @ObservationIgnored private var log: HikeLog?
    @ObservationIgnored private let trails: OverpassTrails
    @ObservationIgnored private let elevation: OpenMeteoElevation
    @ObservationIgnored private let location: (any HikeLocating)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var deleting: Task<Void, Never>?
    @ObservationIgnored private var lookingUp: Set<String> = []

    /// How long Undo stays after a delete.
    public static let undoSeconds: Double = 5
    /// How much of each end of a route is left off a shared picture.
    public static let privacyTrim = 200.0

    public init(
        log: HikeLog?, trails: OverpassTrails = OverpassTrails(), elevation: OpenMeteoElevation = OpenMeteoElevation(),
        location: (any HikeLocating)?, units: HikeUnits = HikeUnits(locale: .autoupdatingCurrent),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.log = log
        self.trails = trails
        self.elevation = elevation
        self.location = location
        self.units = units
        self.now = now
    }

    // MARK: Loading

    public func load() async {
        guard let log else {
            phase = .failed
            return
        }
        hikes = await log.hikes()
        saved = await log.savedTrails()
        if let cached = await log.nearby() {
            nearby = cached.trails
            here = cached.around
            nearbyState = .ready
        }
        phase = .ready
    }

    /// Trails near where the person is: the sealed list if it's fresh and near, else a new one from
    /// OpenStreetMap. `force` is a pull to refresh.
    public func loadNearby(force: Bool = false) async {
        guard phase == .ready, let log, nearbyState != .loading else { return }
        guard let location else {
            nearbyState = .noLocation
            return
        }
        let before = nearbyState
        nearbyState = .loading
        guard let found = await location.currentLocation() else {
            nearbyState = location.access == .denied ? .noLocation : (nearby.isEmpty ? .failed : before)
            return
        }
        if !force, let cached = await log.nearby(), cached.isFresh(at: now(), near: found) {
            nearby = cached.trails
            here = found
            nearbyState = .ready
            return
        }
        do {
            let list = try await trails.trails(near: found)
            nearby = list
            here = found
            nearbyState = .ready
            try? await log.keep(NearbyTrails(around: found.rough, fetchedAt: now(), trails: list))
        } catch HikingError.offline {
            nearbyState = .offline
        } catch {
            nearbyState = .failed
        }
    }

    public func pull() async {
        await loadNearby(force: true)
    }

    /// The trail as best known: the saved copy, with its profile, before the one in the list.
    public func trail(_ id: String) -> Trail? {
        saved.first { $0.id == id } ?? nearby.first { $0.id == id }
    }

    public func isSaved(_ trail: Trail) -> Bool { saved.contains { $0.id == trail.id } }

    /// Looks up a trail's elevation profile once, and keeps it with the trail.
    public func lookUpProfile(_ trail: Trail) async {
        guard self.trail(trail.id)?.profile == nil, !lookingUp.contains(trail.id) else { return }
        lookingUp.insert(trail.id)
        defer { lookingUp.remove(trail.id) }
        guard let profile = try? await elevation.profile(of: trail) else { return }
        if let index = nearby.firstIndex(where: { $0.id == trail.id }) {
            nearby[index].profile = profile
            if let here { try? await log?.keep(NearbyTrails(around: here.rough, fetchedAt: now(), trails: nearby)) }
        }
        if let index = saved.firstIndex(where: { $0.id == trail.id }) {
            saved[index].profile = profile
            try? await log?.save(saved[index])
        }
    }

    // MARK: Saving trails for offline use

    /// Keeps the trail's route, profile and details sealed on the iPhone, so it opens with no signal.
    public func save(_ trail: Trail) async {
        var kept = self.trail(trail.id) ?? trail
        kept.savedAt = now()
        do {
            try await log?.save(kept)
            saved.insert(kept, at: 0)
            notice = "Saved \(kept.name) for offline use"
        } catch {
            notice = "\(kept.name) couldn't be saved on this iPhone"
        }
    }

    public func forget(_ trail: Trail) async {
        try? await log?.forget(trail: trail.id)
        saved.removeAll { $0.id == trail.id }
    }

    // MARK: Recording

    public var locationAccess: HikeLocationAccess { location?.access ?? .denied }

    public func startRecording(on trail: Trail? = nil) {
        guard recording == nil, let location else { return }
        recording = Recording(startedAt: now(), trail: trail)
        location.start { [weak self] point, accuracy, time in
            self?.take(point, accuracy: accuracy, at: time)
        }
    }

    func take(_ point: GeoPoint, accuracy: Double, at time: Date) {
        guard recording != nil else { return }
        recording?.track.add(point, accuracy: accuracy, at: time)
    }

    public func pause() { recording?.track.pause() }
    public func resume() { recording?.track.resume() }

    /// Seals the hike on the iPhone. A recording with no line to it is thrown away instead.
    @discardableResult
    public func finish() async -> Hike? {
        guard let current = recording else { return nil }
        location?.stop()
        recording = nil
        let segments = current.track.kept.map { GeoLine.thinned($0, spacing: TrackBuilder.spacing) }
        guard !segments.isEmpty else {
            notice = "That hike was too short to keep"
            return nil
        }
        let hike = Hike(
            title: current.title, startedAt: current.startedAt, endedAt: now(), seconds: current.track.movingSeconds,
            segments: segments, trailID: current.trail?.id
        )
        do {
            try await log?.save(hike)
            hikes.insert(hike, at: 0)
            return hike
        } catch {
            notice = "The hike couldn't be saved on this iPhone"
            return nil
        }
    }

    public func discard() {
        location?.stop()
        recording = nil
    }

    // MARK: Hikes

    public func rename(_ hike: Hike, to title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = hikes.firstIndex(where: { $0.id == hike.id }) else { return }
        hikes[index].title = clean
        try? await log?.save(hikes[index])
    }

    /// Takes the hike off the list at once and deletes it for good after five seconds, unless Undo is pressed.
    public func delete(_ hike: Hike) {
        finishPendingDelete()
        hikes.removeAll { $0.id == hike.id }
        recentlyDeleted = hike
        deleting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled else { return }
            await self?.finishPendingDelete()
        }
    }

    public func undoDelete() {
        deleting?.cancel()
        deleting = nil
        guard let hike = recentlyDeleted else { return }
        recentlyDeleted = nil
        hikes.append(hike)
        hikes.sort { $0.startedAt > $1.startedAt }
    }

    func finishPendingDelete() async {
        deleting?.cancel()
        deleting = nil
        guard let hike = recentlyDeleted else { return }
        recentlyDeleted = nil
        try? await log?.delete(hike: hike.id)
    }

    // MARK: Sharing

    /// The draft Social's composer opens with. The route picture leaves off the first and last 200 m.
    public func draft(for hike: Hike, image: Data?) -> PostDraft {
        PostDraft(title: hike.title, body: hike.postBody(units: units), image: image, source: hike.ref)
    }

    /// The route to draw in a shared picture, with its ends trimmed for privacy.
    public static func sharedRoute(of hike: Hike) -> [[GeoPoint]] {
        let whole = hike.points
        let trimmed = GeoLine.trimmed(whole, by: privacyTrim)
        return trimmed.count > 1 ? [trimmed] : []
    }

    public func share(_ hike: Hike, image: Data?) {
        onShare?(draft(for: hike, image: image))
    }

    // MARK: Home tile

    /// The distance walked in the month so far, and how many hikes.
    public func month(at date: Date = Date()) -> (metres: Double, count: Int) {
        let calendar = Calendar.current
        let these = hikes.filter { calendar.isDate($0.startedAt, equalTo: date, toGranularity: .month) }
        return (these.reduce(0) { $0 + $1.metres }, these.count)
    }

    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        if let recording {
            return ModuleGlance(lines: ["Recording · \(units.distance(recording.track.metres))"])
        }
        if let last = hikes.first {
            let month = month()
            return ModuleGlance(lines: [
                "\(last.title) · \(units.distance(last.metres))",
                "\(units.distance(month.metres)) this month",
            ])
        }
        return ModuleGlance(lines: ["Record a hike or find trails nearby"], isQuiet: true)
    }

    // MARK: Key change

    /// Stops recording and closes the log, so nothing more is written under the old key.
    public func stopForKeyChange() async {
        location?.stop()
        recording = nil
        await finishPendingDelete()
        await log?.close()
        log = nil
        hikes = []
        saved = []
        nearby = []
        phase = .failed
    }
}
