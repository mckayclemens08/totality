import Foundation
import Testing
import TotalityCore
@testable import TotalityHiking

final class MemoryBlobStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    func exists(_ name: String) throws -> Bool { lock.withLock { blobs[name] != nil } }
    var all: [String: Data] { lock.withLock { blobs } }
}

final class FakeHTTP: HikingHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Data] = [:]
    private var asked: [(URL, [String: String])] = []
    var failure: HikingError?

    func answer(_ host: String, with json: String) { lock.withLock { answers[host] = Data(json.utf8) } }
    var requests: [URL] { lock.withLock { asked.map(\.0) } }
    var headers: [[String: String]] { lock.withLock { asked.map(\.1) } }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        let (data, failure) = lock.withLock { () -> (Data?, HikingError?) in
            asked.append((url, headers))
            return (answers[url.host ?? ""], self.failure)
        }
        if let failure { throw failure }
        guard let data else { throw HikingError.failed }
        return data
    }
}

@MainActor
final class FakeLocation: HikeLocating {
    var access = HikeLocationAccess.allowed
    var spot: GeoPoint? = GeoPoint(latitude: 40.2448, longitude: -111.6370)
    private(set) var onFix: (@MainActor (GeoPoint, Double, Date) -> Void)?
    private(set) var stopped = 0

    func currentLocation() async -> GeoPoint? { access == .allowed ? spot : nil }
    func start(_ onFix: @escaping @MainActor (GeoPoint, Double, Date) -> Void) { self.onFix = onFix }
    func stop() {
        onFix = nil
        stopped += 1
    }
    func send(_ point: GeoPoint, accuracy: Double = 5, at time: Date) { onFix?(point, accuracy, time) }
}

/// A line walked north, a point every `step` metres, climbing `rise` metres per point.
func walk(points: Int, step: Double = 10, rise: Double = 0, from start: GeoPoint = GeoPoint(latitude: 40.25, longitude: -111.63, elevation: 1500)) -> [GeoPoint] {
    let degrees = step / 111_195
    return (0..<points).map { index in
        GeoPoint(latitude: start.latitude + Double(index) * degrees, longitude: start.longitude, elevation: (start.elevation ?? 0) + Double(index) * rise)
    }
}

let overpassAnswer = """
{"elements":[
 {"type":"relation","id":11,"tags":{"route":"hiking","name":"Y Mountain Trail","sac_scale":"mountain_hiking"},
  "members":[{"type":"way","ref":1,"role":"","geometry":[{"lat":40.2450,"lon":-111.6280},{"lat":40.2480,"lon":-111.6240},{"lat":40.2510,"lon":-111.6200}]},
             {"type":"node","ref":9,"role":"","lat":40.0,"lon":-111.0}]},
 {"type":"way","id":21,"tags":{"highway":"path","name":"Y Mountain Trail"},"geometry":[{"lat":40.2450,"lon":-111.6280},{"lat":40.2480,"lon":-111.6240}]},
 {"type":"way","id":31,"tags":{"highway":"footway","name":"Provo River Parkway","surface":"asphalt"},"geometry":[{"lat":40.2440,"lon":-111.6380},{"lat":40.2500,"lon":-111.6380}]},
 {"type":"way","id":32,"tags":{"highway":"footway","name":"Provo River Parkway"},"geometry":[{"lat":40.2500,"lon":-111.6380},{"lat":40.2560,"lon":-111.6380}]},
 {"type":"way","id":41,"tags":{"highway":"path","name":"Tiny Spur"},"geometry":[{"lat":40.2440,"lon":-111.6370},{"lat":40.2441,"lon":-111.6370}]},
 {"type":"way","id":51,"tags":{"highway":"path"},"geometry":[{"lat":40.2,"lon":-111.6},{"lat":40.3,"lon":-111.6}]}
]}
"""

@Suite struct GeoTests {
    @Test func distanceIsAboutRight() {
        let a = GeoPoint(latitude: 40.0, longitude: -111.0), b = GeoPoint(latitude: 41.0, longitude: -111.0)
        #expect(abs(a.distance(to: b) - 111_195) < 200)
    }

    @Test func climbIgnoresJitterButCountsRealRises() {
        #expect(GeoLine.climb([100, 101, 100, 101, 100, 101]) == 0)
        #expect(GeoLine.climb([100, 110, 105, 120]) == 25)
        #expect(GeoLine.climb([]) == 0)
    }

    @Test func thinningKeepsEndsAndSpacing() {
        let line = walk(points: 21, step: 1)
        let thin = GeoLine.thinned(line, spacing: 5)
        #expect(thin.first == line.first && thin.last == line.last)
        #expect(thin.count < line.count)
    }

    @Test func samplingCapsThePoints() {
        let line = walk(points: 500)
        let sampled = GeoLine.sampled(line, count: 100)
        #expect(sampled.count == 100)
        #expect(sampled.first == line.first && sampled.last == line.last)
    }

    @Test("The shared picture leaves off 200 m at each end, and a short line leaves nothing")
    func trimmingHidesTheEnds() {
        let line = walk(points: 101, step: 10) // 1 km
        let trimmed = GeoLine.trimmed(line, by: 200)
        #expect(abs(GeoLine.length(trimmed) - 600) < 25)
        #expect(trimmed.first!.distance(to: line.first!) >= 199)
        #expect(trimmed.last!.distance(to: line.last!) >= 199)
        #expect(GeoLine.trimmed(walk(points: 30, step: 10), by: 200).isEmpty)
    }

    @Test func roughRoundsToAboutAKilometre() {
        let point = GeoPoint(latitude: 40.24486, longitude: -111.63704).rough
        #expect(point.latitude == 40.24 && point.longitude == -111.64)
    }

    @Test func unitsReadNaturally() {
        let metric = HikeUnits(metric: true), us = HikeUnits(metric: false)
        #expect(metric.distance(3900) == "3.9 km")
        #expect(us.distance(1609.344 * 2.4) == "2.4 mi")
        #expect(metric.climb(1074) == "+1,074 m")
        #expect(us.height(100) == "328 ft")
        #expect(metric.pace(seconds: 950, metres: 1000) == "15:50 /km")
        #expect(metric.pace(seconds: 10, metres: 10) == "–")
        #expect(HikeUnits.duration(4368) == "1:12:48")
        #expect(HikeUnits.shortDuration(7080) == "1 h 58 min")
    }
}

@Suite struct DifficultyTests {
    @Test func sacScaleWins() {
        #expect(Difficulty(sacScale: "hiking") == .easy)
        #expect(Difficulty(sacScale: "mountain_hiking") == .moderate)
        #expect(Difficulty(sacScale: "alpine_hiking") == .hard)
        #expect(Difficulty(sacScale: nil) == nil)
        let trail = Trail(id: "way/1", name: "A", lines: [walk(points: 100, step: 100)], sacScale: "hiking", profile: Array(stride(from: 1000.0, to: 2000, by: 10)))
        #expect(trail.difficulty == .easy)
    }

    @Test("The Shenandoah rating: √(feet × 2 × miles)")
    func shenandoah() {
        // 2.7 km and 170 m: √(558 × 2 × 1.68) ≈ 43, easy.
        #expect(Difficulty(metres: 2700, climb: 170) == .easy)
        // 3.9 km and 330 m: √(1083 × 2 × 2.42) ≈ 72, moderate.
        #expect(Difficulty(metres: 3900, climb: 330) == .moderate)
        // 23 km and 1,350 m: hard.
        #expect(Difficulty(metres: 23000, climb: 1350) == .hard)
        #expect(Difficulty(metres: 4000, climb: nil) == .easy)
        #expect(Difficulty(metres: 20000, climb: nil) == .hard)
    }
}

@Suite struct SourceTests {
    @Test("Overpass is asked with a rough location, a named User-Agent and nothing else")
    func overpassRequest() async throws {
        let http = FakeHTTP()
        http.answer("overpass-api.de", with: overpassAnswer)
        _ = try await OverpassTrails(http: http).trails(near: GeoPoint(latitude: 40.24486, longitude: -111.63704))
        let url = try #require(http.requests.first)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "data" }?.value)
        #expect(query.contains("around:8000,40.24,-111.64"))
        #expect(!query.contains("40.2448"))
        #expect(http.headers.first?["User-Agent"]?.hasPrefix("Totality-Hiking/") == true)
    }

    @Test("Routes come first by name, ways with one name join, and short or nameless bits are dropped")
    func overpassParse() throws {
        let here = GeoPoint(latitude: 40.244, longitude: -111.637)
        let trails = try OverpassTrails.parse(Data(overpassAnswer.utf8), near: here)
        #expect(trails.map(\.name) == ["Provo River Parkway", "Y Mountain Trail"])
        let parkway = trails[0]
        #expect(parkway.lines.count == 2)
        #expect(parkway.id == "way/31")
        #expect(parkway.surface == "asphalt")
        let y = trails[1]
        #expect(y.id == "relation/11" && y.kind == "Hiking route")
        #expect(y.difficulty == .moderate)
        #expect(throws: HikingError.badAnswer) { try OverpassTrails.parse(Data("nope".utf8), near: here) }
    }

    @Test("The elevation lookup sends at most 100 of the trail's own points")
    func elevation() async throws {
        let http = FakeHTTP()
        let heights = (0..<100).map { String(1500 + $0 * 3) }.joined(separator: ",")
        http.answer("api.open-meteo.com", with: "{\"elevation\":[\(heights)]}")
        let trail = Trail(id: "way/1", name: "Long", lines: [walk(points: 400)])
        let profile = try await OpenMeteoElevation(http: http).profile(of: trail)
        #expect(profile.count == 100)
        let url = try #require(http.requests.first)
        let lats = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "latitude" }?.value
        #expect(lats?.split(separator: ",").count == 100)
        #expect(throws: HikingError.badAnswer) { try OpenMeteoElevation.parse(Data("{\"elevation\":[1]}".utf8), count: 2) }
    }
}

@Suite struct TrackTests {
    @Test("Vague fixes and standing still add nothing; a pause starts a new stretch")
    func building() {
        var track = TrackBuilder()
        let line = walk(points: 10, step: 10, rise: 1)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, point) in line.enumerated() { track.add(point, accuracy: 5, at: start.addingTimeInterval(Double(index) * 10)) }
        let still = track.add(line[9], accuracy: 5, at: start.addingTimeInterval(100))
        let vague = track.add(walk(points: 12, step: 10)[11], accuracy: 80, at: start.addingTimeInterval(110))
        #expect(!still && !vague)
        #expect(abs(track.metres - 90) < 2)
        #expect(track.movingSeconds == 100)
        track.pause()
        let whilePaused = track.add(line[0], accuracy: 5, at: start.addingTimeInterval(500))
        #expect(!whilePaused)
        track.resume()
        let more = walk(points: 3, step: 10, from: GeoPoint(latitude: 40.3, longitude: -111.63, elevation: 1600))
        for (index, point) in more.enumerated() { track.add(point, accuracy: 5, at: start.addingTimeInterval(600 + Double(index) * 10)) }
        #expect(track.kept.count == 2)
        #expect(track.movingSeconds == 120, "the time paused isn't counted")
        #expect(abs(track.metres - 110) < 3, "the jump while paused isn't counted")
    }
}

@Suite struct HikeLogTests {
    @Test("Everything is sealed: the folder holds no names, places or coordinates")
    func sealed() async throws {
        let store = MemoryBlobStore()
        let log = HikeLog(store: store, rootKey: try ContentRootKey.generate())
        let hike = Hike(title: "Y Mountain Trail", startedAt: Date(), endedAt: Date(), seconds: 3600, segments: [walk(points: 20)])
        try await log.save(hike)
        try await log.save(Trail(id: "relation/11", name: "Stewart Falls", lines: [walk(points: 5)], savedAt: Date()))
        try await log.keep(NearbyTrails(around: GeoPoint(latitude: 40.24, longitude: -111.64), fetchedAt: Date(), trails: []))
        #expect(store.all.count == 3)
        for (name, data) in store.all {
            #expect(!name.contains("relation") && !name.lowercased().contains("stewart"))
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("Y Mountain") && !text.contains("Stewart") && !text.contains("40.2"))
        }
        #expect(await log.hikes() == [hike])
        #expect(await log.savedTrails().map(\.name) == ["Stewart Falls"])
        #expect(await log.nearby()?.around.latitude == 40.24)
    }

    @Test("Every blob is one a key move knows how to seal again")
    func keyMoveCoversEveryBlob() async throws {
        let store = MemoryBlobStore()
        let log = HikeLog(store: store, rootKey: try ContentRootKey.generate())
        try await log.save(Hike(title: "A", startedAt: Date(), endedAt: Date(), seconds: 1, segments: [walk(points: 3)]))
        try await log.save(Trail(id: "way/1", name: "B", lines: [walk(points: 3)]))
        try await log.keep(NearbyTrails(around: GeoPoint(latitude: 1, longitude: 1), fetchedAt: Date(), trails: []))
        for name in store.all.keys {
            let match = HikeLog.sealedPurposes.first { name.hasSuffix($0.key) && UUID(uuidString: String(name.dropLast($0.key.count))) != nil }
            #expect(match != nil, "\(name) wouldn't be moved")
        }
    }

    @Test func closedRefusesWrites() async throws {
        let log = HikeLog(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        await log.close()
        await #expect(throws: HikingError.closed) {
            try await log.save(Hike(title: "A", startedAt: Date(), endedAt: Date(), seconds: 1, segments: []))
        }
    }

    @Test func nearbyIsFreshForADayAndNearby() {
        let found = NearbyTrails(around: GeoPoint(latitude: 40.24, longitude: -111.64), fetchedAt: Date(timeIntervalSince1970: 0), trails: [])
        #expect(found.isFresh(at: Date(timeIntervalSince1970: 3600), near: GeoPoint(latitude: 40.241, longitude: -111.641)))
        #expect(!found.isFresh(at: Date(timeIntervalSince1970: 90_000), near: GeoPoint(latitude: 40.24, longitude: -111.64)))
        #expect(!found.isFresh(at: Date(timeIntervalSince1970: 3600), near: GeoPoint(latitude: 40.40, longitude: -111.64)))
    }
}

@MainActor
@Suite struct HikingModelTests {
    func model(http: FakeHTTP = FakeHTTP(), location: FakeLocation = FakeLocation(), store: MemoryBlobStore = MemoryBlobStore()) throws -> HikingModel {
        HikingModel(
            log: HikeLog(store: store, rootKey: try ContentRootKey.generate()),
            trails: OverpassTrails(http: http), elevation: OpenMeteoElevation(http: http),
            location: location, units: HikeUnits(metric: true)
        )
    }

    @Test("Nearby asks once, then opens from the sealed list while it's fresh")
    func nearbyCaches() async throws {
        let http = FakeHTTP()
        http.answer("overpass-api.de", with: overpassAnswer)
        let model = try model(http: http)
        await model.load()
        await model.loadNearby()
        #expect(model.nearbyState == .ready)
        #expect(model.nearby.count == 2)
        await model.loadNearby()
        #expect(http.requests.count == 1)
        await model.pull()
        #expect(http.requests.count == 2)
    }

    @Test("Offline, denied and empty each have their own state")
    func nearbyStates() async throws {
        let http = FakeHTTP()
        http.failure = .offline
        let model = try model(http: http)
        await model.load()
        await model.loadNearby()
        #expect(model.nearbyState == .offline)

        let location = FakeLocation()
        location.access = .denied
        let denied = try self.model(location: location)
        await denied.load()
        await denied.loadNearby()
        #expect(denied.nearbyState == .noLocation)
        #expect(denied.glance?.isQuiet == true)
    }

    @Test("Recording seals a hike, and a recording with no line is thrown away")
    func recording() async throws {
        let location = FakeLocation()
        let store = MemoryBlobStore()
        let model = try model(location: location, store: store)
        await model.load()
        model.startRecording()
        let start = Date()
        for (index, point) in walk(points: 30, step: 10, rise: 2).enumerated() { location.send(point, at: start.addingTimeInterval(Double(index) * 6)) }
        #expect(model.glance?.lines.first?.hasPrefix("Recording") == true)
        let hike = try #require(await model.finish())
        #expect(abs(hike.metres - 290) < 5)
        #expect((54...58).contains(hike.climb), "a GPS climb counts in steps of at least 3 m")
        #expect(location.stopped == 1)
        #expect(model.hikes == [hike])
        #expect(store.all.keys.contains { $0.hasSuffix(HikeLog.hikeSuffix) })

        model.startRecording()
        #expect(await model.finish() == nil)
        #expect(model.hikes.count == 1)
    }

    @Test("Delete waits five seconds, and Undo brings the hike back")
    func deleteAndUndo() async throws {
        let store = MemoryBlobStore()
        let model = try model(store: store)
        await model.load()
        model.startRecording()
        for (index, point) in walk(points: 5).enumerated() { model.take(point, accuracy: 5, at: Date().addingTimeInterval(Double(index))) }
        let hike = try #require(await model.finish())
        model.delete(hike)
        #expect(model.hikes.isEmpty && model.recentlyDeleted == hike)
        model.undoDelete()
        #expect(model.hikes == [hike])
        model.delete(hike)
        await model.finishPendingDelete()
        #expect(!store.all.keys.contains { $0.hasSuffix(HikeLog.hikeSuffix) })
    }

    @Test("A saved trail keeps its profile for offline use")
    func saveForOffline() async throws {
        let http = FakeHTTP()
        http.answer("overpass-api.de", with: overpassAnswer)
        let heights = (0..<3).map { String(1500 + $0 * 100) }.joined(separator: ",")
        http.answer("api.open-meteo.com", with: "{\"elevation\":[\(heights)]}")
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let model = HikingModel(log: HikeLog(store: store, rootKey: key), trails: OverpassTrails(http: http), elevation: OpenMeteoElevation(http: http), location: FakeLocation(), units: HikeUnits(metric: true))
        await model.load()
        await model.loadNearby()
        let y = try #require(model.nearby.first { $0.name == "Y Mountain Trail" })
        await model.lookUpProfile(y)
        await model.save(y)
        // Offline, on a fresh launch, it's all still there.
        let reopened = HikingModel(log: HikeLog(store: store, rootKey: key), location: nil, units: HikeUnits(metric: true))
        await reopened.load()
        #expect(reopened.saved.first?.profile?.count == 3)
        #expect(reopened.saved.first?.climb == 200)
    }

    @Test("Sharing hands over a draft with a ref to the hike, and posts nothing")
    func share() async throws {
        let model = try model()
        await model.load()
        model.startRecording()
        for (index, point) in walk(points: 101, step: 10, rise: 1).enumerated() { model.take(point, accuracy: 5, at: Date().addingTimeInterval(Double(index) * 5)) }
        let hike = try #require(await model.finish())
        var drafts: [PostDraft] = []
        model.onShare = { drafts.append($0) }
        model.share(hike, image: Data([1, 2, 3]))
        let draft = try #require(drafts.first)
        #expect(draft.source.module == .hiking && draft.source.kind == .hike && draft.source.id == hike.id)
        #expect(draft.title == hike.title)
        #expect(draft.body.contains("1.0 km") && draft.body.contains(HikeUnits(metric: true).climb(hike.climb)))
        #expect(draft.image == Data([1, 2, 3]))
        let route = HikingModel.sharedRoute(of: hike).flatMap { $0 }
        #expect(route.first!.distance(to: hike.points.first!) >= 199)
    }

    @Test func keyChangeStopsRecordingAndCloses() async throws {
        let location = FakeLocation()
        let model = try model(location: location)
        await model.load()
        model.startRecording()
        await model.stopForKeyChange()
        #expect(model.recording == nil && location.stopped == 1)
        #expect(model.phase == .failed)
    }
}

@Suite struct HikingModuleTests {
    @Test("Search finds saved hikes and trails by name, on the device")
    func search() async throws {
        let log = HikeLog(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        let hike = Hike(title: "Y Mountain at dawn", startedAt: Date(), endedAt: Date(), seconds: 60, segments: [walk(points: 3)])
        try await log.save(hike)
        try await log.save(Trail(id: "relation/7", name: "Stewart Falls", lines: [walk(points: 3)], savedAt: Date()))
        let module = HikingModule(log: log, units: { HikeUnits(metric: true) })
        #expect(try await module.search("mountain").map(\.itemID) == [hike.id.uuidString])
        #expect(try await module.search("falls").map(\.itemID) == ["relation/7"])
        #expect(try await module.search("").isEmpty)
        #expect(module.kinds == [.hike])
    }

    @Test func registersWithoutClashing() throws {
        let registry = try ModuleRegistry(handlers: [HikingModule(log: nil)])
        let ref = ContentRef(module: .hiking, kind: .hike, id: UUID(), keyRef: .plain, preview: .init(title: "A"))
        #expect(registry.handler(for: ref)?.module == .hiking)
    }
}
