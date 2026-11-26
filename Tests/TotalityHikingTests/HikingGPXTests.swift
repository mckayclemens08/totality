import Foundation
import Testing
import TotalityCore
@testable import TotalityHiking

// MARK: Samples

/// A Garmin-style GPX 1.1 file: namespaces, a metadata name, fractional-second times and extensions.
let garminGPX = """
<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="Garmin Connect" version="1.1" xmlns="http://www.topografix.com/GPX/1/1"
 xmlns:ns3="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
 <metadata><name>Mount Olympus via Wasatch Trail</name><time>2026-09-12T14:03:11.000Z</time></metadata>
 <trk><name>Morning hike</name><type>hiking</type>
  <trkseg>
   <trkpt lat="40.69950" lon="-111.80200"><ele>1560.2</ele><time>2026-09-12T14:03:11.000Z</time>
    <extensions><ns3:TrackPointExtension><ns3:hr>96</ns3:hr></ns3:TrackPointExtension></extensions></trkpt>
   <trkpt lat="40.70050" lon="-111.80250"><ele>1571.8</ele><time>2026-09-12T14:04:00.000Z</time></trkpt>
   <trkpt lat="40.70150" lon="-111.80300"><ele>1590.0</ele><time>2026-09-12T14:05:00Z</time></trkpt>
   <trkpt lat="40.70250" lon="-111.80350"><ele>1612.4</ele><time>2026-09-12T14:06:00Z</time></trkpt>
  </trkseg>
 </trk>
</gpx>
"""

/// A GPX 1.0 file with no namespace, as older devices write it, with a waypoint.
let oldGPX = """
<?xml version="1.0"?>
<gpx version="1.0" creator="GPSBabel">
 <wpt lat="40.0" lon="-111.0"><name>Camp</name></wpt>
 <trk><name>Old Trail</name><trkseg>
  <trkpt lat="40.0000" lon="-111.0000"><ele>2000</ele></trkpt>
  <trkpt lat="40.0010" lon="-111.0000"><ele>2010</ele></trkpt>
  <trkpt lat="40.0020" lon="-111.0000"><ele>2025</ele></trkpt>
 </trkseg></trk>
</gpx>
"""

let noElevationGPX = """
<?xml version="1.0"?><gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
<trk><name>Flat file</name><trkseg>
<trkpt lat="40.000" lon="-111.000"/><trkpt lat="40.001" lon="-111.000"/><trkpt lat="40.002" lon="-111.000"/>
</trkseg></trk></gpx>
"""

let twoTracksGPX = """
<?xml version="1.0"?><gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
<wpt lat="40.5" lon="-111.5"><name>Spring</name></wpt><wpt lat="40.6" lon="-111.6"/>
<trk><name>Day one</name><trkseg>
<trkpt lat="40.000" lon="-111.000"><ele>1000</ele></trkpt><trkpt lat="40.002" lon="-111.000"><ele>1050</ele></trkpt>
</trkseg></trk>
<trk><name>Day two</name><trkseg>
<trkpt lat="40.004" lon="-111.000"><ele>1100</ele></trkpt><trkpt lat="40.006" lon="-111.000"><ele>1150</ele></trkpt>
</trkseg><trkseg>
<trkpt lat="40.008" lon="-111.000"><ele>1200</ele></trkpt><trkpt lat="40.010" lon="-111.000"><ele>1250</ele></trkpt>
</trkseg></trk></gpx>
"""

let routeOnlyGPX = """
<?xml version="1.0"?><gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
<rte><name>Planned route</name>
<rtept lat="40.000" lon="-111.000"><ele>1000</ele></rtept><rtept lat="40.003" lon="-111.000"><ele>1030</ele></rtept>
</rte></gpx>
"""

let waypointsOnlyGPX = """
<?xml version="1.0"?><gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
<wpt lat="40.0" lon="-111.0"><name>One</name></wpt><wpt lat="40.1" lon="-111.1"><name>Two</name></wpt></gpx>
"""

/// An entity bomb. It must be refused before any entity is expanded.
let entityBombGPX = """
<?xml version="1.0"?>
<!DOCTYPE gpx [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>
<gpx version="1.1" creator="x"><metadata><name>&b;</name></metadata>
<trk><trkseg><trkpt lat="1" lon="1"/><trkpt lat="1.1" lon="1"/></trkseg></trk></gpx>
"""

let externalEntityGPX = """
<?xml version="1.0"?>
<!DOCTYPE gpx SYSTEM "file:///etc/passwd">
<gpx version="1.1" creator="x"><trk><trkseg><trkpt lat="1" lon="1"/><trkpt lat="1.1" lon="1"/></trkseg></trk></gpx>
"""

private func data(_ text: String) -> Data { Data(text.utf8) }

private func recordedHike(points: Int = 100, step: Double = 10, rise: Double = 0.5) -> Hike {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    return Hike(
        title: "Lake Blanche", startedAt: start, endedAt: start.addingTimeInterval(3600), seconds: 3300,
        segments: [walk(points: points, step: step, rise: rise)]
    )
}

// MARK: Reading

@Suite struct GPXReaderTests {
    @Test func readsAGarminFile() throws {
        let file = try GPXReader.read(data(garminGPX))
        #expect(file.name == "Mount Olympus via Wasatch Trail")
        #expect(file.segments.count == 1)
        let points = try #require(file.segments.first)
        #expect(points.count == 4)
        #expect(points[0].point.elevation == 1560.2)
        #expect(points[0].point.latitude == 40.6995)
        #expect(points[0].time != nil)
        #expect(points[2].time == points[3].time?.addingTimeInterval(-60))
        // The extension's heart rate is not mistaken for anything.
        #expect(file.waypoints == 0)
    }

    @Test func readsAnOldNamespacelessFileAndCountsWaypoints() throws {
        let file = try GPXReader.read(data(oldGPX))
        #expect(file.name == "Old Trail")
        #expect(file.segments.first?.count == 3)
        #expect(file.waypoints == 1)
    }

    @Test func fallsBackToARoute() throws {
        let file = try GPXReader.read(data(routeOnlyGPX))
        #expect(file.name == "Planned route")
        #expect(file.segments.first?.count == 2)
    }

    @Test func aFileWithOnlyWaypointsHasNoRoute() {
        #expect(throws: GPXError.noRoute(waypoints: 2)) { try GPXReader.read(data(waypointsOnlyGPX)) }
    }

    @Test func refusesWhatIsNotGPX() {
        #expect(throws: GPXError.notGPX) { try GPXReader.read(data("<html><body>hi</body></html>")) }
        #expect(throws: GPXError.notGPX) { try GPXReader.read(data("not xml at all")) }
        #expect(throws: GPXError.notGPX) { try GPXReader.read(Data()) }
        #expect(throws: GPXError.notGPX) { try GPXReader.read(data("<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"1\"></gpx>")) }
    }

    @Test func refusesEntitiesAndDocumentTypes() {
        #expect(throws: GPXError.notGPX) { try GPXReader.read(data(entityBombGPX)) }
        #expect(throws: GPXError.notGPX) { try GPXReader.read(data(externalEntityGPX)) }
    }

    @Test func refusesAFileOverTenMegabytes() {
        let padding = String(repeating: " ", count: GPXReader.maxBytes)
        #expect(throws: GPXError.tooBig) { try GPXReader.read(data(garminGPX + padding)) }
    }

    @Test func aFileJustUnderTheCapStillReads() throws {
        let padding = String(repeating: " ", count: GPXReader.maxBytes - garminGPX.utf8.count)
        let file = try GPXReader.read(data(garminGPX + padding))
        #expect(file.segments.first?.count == 4)
    }

    @Test func skipsPointsOffTheEarth() throws {
        let text = """
        <gpx version="1.1"><trk><trkseg><trkpt lat="95" lon="10"/><trkpt lat="40" lon="-111"/><trkpt lat="40.001" lon="-111"/></trkseg></trk></gpx>
        """
        #expect(try GPXReader.read(data(text)).segments.first?.count == 2)
    }

    @Test func readsAFileFromDiskAndRefusesOneTooBigBeforeReadingIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("Small.gpx")
        try data(garminGPX).write(to: small)
        #expect(try GPXImport.read(contentsOf: small) == data(garminGPX))
        let big = folder.appendingPathComponent("Big.gpx")
        try Data(count: GPXReader.maxBytes + 1).write(to: big)
        #expect(throws: GPXError.tooBig) { try GPXImport.read(contentsOf: big) }
    }
}

// MARK: Importing

@Suite struct GPXImportTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func makesATrailWithItsFigures() throws {
        let result = try GPXImport.trail(from: data(garminGPX), fallbackName: "file.gpx", now: now)
        let trail = result.trail
        #expect(trail.name == "Mount Olympus via Wasatch Trail")
        #expect(trail.isImported)
        #expect(trail.id.hasPrefix("gpx/"))
        #expect(trail.sourceURL == nil)
        #expect(trail.kind == "GPX file")
        #expect(result.hasElevation)
        #expect(trail.highest == 1612.4)
        #expect(trail.climb ?? 0 > 50)
        #expect(trail.metres > 300 && trail.metres < 450)
        #expect(trail.savedAt == now)
    }

    @Test func aFileWithNoElevationStillSaves() throws {
        let result = try GPXImport.trail(from: data(noElevationGPX), fallbackName: "Flat.gpx", now: now)
        #expect(!result.hasElevation)
        #expect(result.trail.profile == nil)
        #expect(result.trail.climb == nil)
        #expect(result.trail.metres > 200)
    }

    @Test func joinsTracksInOrderAndLeavesWaypointsOut() throws {
        let result = try GPXImport.trail(from: data(twoTracksGPX), fallbackName: "x", now: now)
        #expect(result.trail.lines.count == 1)
        let line = try #require(result.trail.lines.first)
        #expect(line.count == 6)
        #expect(line.map(\.latitude) == line.map(\.latitude).sorted())
        #expect(line.first?.latitude == 40.000)
        #expect(line.last?.latitude == 40.010)
        // Waypoints at 40.5 and 40.6 are not part of the route.
        #expect(!line.contains { $0.latitude > 41 || abs($0.latitude - 40.5) < 0.01 })
        #expect(result.trail.name == "Day one")
    }

    @Test func thinsCrowdedPointsToAboutFiveMetres() throws {
        var text = "<gpx version=\"1.1\"><trk><trkseg>"
        for index in 0..<400 { text += "<trkpt lat=\"\(40 + Double(index) * 0.000009)\" lon=\"-111\"><ele>\(1000 + index)</ele></trkpt>" }
        text += "</trkseg></trk></gpx>"
        let line = try #require(try GPXImport.trail(from: data(text), fallbackName: "x", now: now).trail.lines.first)
        #expect(line.count < 120 && line.count > 50)
    }

    @Test func nameFallsBackToTheFileName() throws {
        let text = "<gpx version=\"1.1\"><trk><trkseg><trkpt lat=\"40\" lon=\"-111\"/><trkpt lat=\"40.001\" lon=\"-111\"/></trkseg></trk></gpx>"
        #expect(try GPXImport.trail(from: data(text), fallbackName: "Mount Olympus Loop.gpx", now: now).trail.name == "Mount Olympus Loop")
        #expect(try GPXImport.trail(from: data(text), fallbackName: "  ", now: now).trail.name == "Imported trail")
    }

    @Test func errorsSaySomething() {
        for error in [GPXError.tooBig, .notGPX, .noRoute(waypoints: 0), .noRoute(waypoints: 14), .tooShortToTrim] {
            #expect(!error.title.isEmpty && !error.detail.isEmpty)
        }
        #expect(GPXError.noRoute(waypoints: 14).detail.contains("14 waypoints"))
    }
}

// MARK: Exporting

@Suite struct GPXExportTests {
    @Test func roundTripsThroughTheReader() throws {
        let hike = recordedHike()
        let xml = try GPXExport.data(for: hike, options: .init(includeTimeAndElevation: true, trimEnds: false))
        let file = try GPXReader.read(xml)
        #expect(file.name == "Lake Blanche")
        let points = try #require(file.segments.first)
        #expect(points.count == hike.points.count)
        for (read, original) in zip(points, hike.points) {
            #expect(abs(read.point.latitude - original.latitude) < 1e-6)
            #expect(abs(read.point.longitude - original.longitude) < 1e-6)
            #expect(abs((read.point.elevation ?? .nan) - (original.elevation ?? .nan)) < 0.06)
            #expect(read.time != nil)
        }
        #expect(points.first?.time == hike.startedAt)
        #expect(points.last?.time == hike.endedAt)
        let times = points.compactMap(\.time)
        #expect(times == times.sorted())
    }

    @Test func leavesTimeAndElevationOffWhenAsked() throws {
        let xml = try GPXExport.data(for: recordedHike(), options: .init(includeTimeAndElevation: false, trimEnds: false))
        let text = String(decoding: xml, as: UTF8.self)
        #expect(!text.contains("<ele>") && !text.contains("<time>"))
        let file = try GPXReader.read(xml)
        #expect(file.segments.first?.allSatisfy { $0.point.elevation == nil && $0.time == nil } == true)
    }

    @Test func trimsTwoHundredMetresFromEachEnd() throws {
        let hike = recordedHike(points: 200, step: 10)
        let file = try GPXReader.read(GPXExport.data(for: hike))
        let points = try #require(file.segments.first).map(\.point)
        let whole = GeoLine.length(hike.points)
        let kept = GeoLine.length(points)
        #expect(abs(kept - (whole - 400)) < 25)
        #expect(points.first.map { hike.points.first!.distance(to: $0) }! >= 199)
        #expect(points.last.map { hike.points.last!.distance(to: $0) }! >= 199)
    }

    @Test func trimmedTimesStayTrue() throws {
        let hike = recordedHike(points: 200, step: 10)
        let points = try #require(try GPXReader.read(GPXExport.data(for: hike)).segments.first)
        // Cut 200 m off the start of a 1,990 m hike that took an hour.
        let expected = hike.startedAt.addingTimeInterval(3600 * 200 / GeoLine.length(hike.points))
        #expect(abs((points.first?.time?.timeIntervalSince(expected) ?? 999)) < 25)
    }

    @Test func aHikeTooShortToTrimSaysSo() {
        let hike = recordedHike(points: 20, step: 10)
        #expect(throws: GPXError.tooShortToTrim) { try GPXExport.data(for: hike) }
        #expect((try? GPXExport.data(for: hike, options: .init(trimEnds: false))) != nil)
    }

    @Test func keepsStretchesApart() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let hike = Hike(
            title: "Two stretches", startedAt: start, endedAt: start.addingTimeInterval(7200), seconds: 7000,
            segments: [walk(points: 80), walk(points: 80, from: GeoPoint(latitude: 40.26, longitude: -111.63, elevation: 1700))]
        )
        let file = try GPXReader.read(GPXExport.data(for: hike, options: .init(trimEnds: false)))
        #expect(file.segments.count == 2)
        let trimmed = try GPXReader.read(GPXExport.data(for: hike))
        #expect(trimmed.segments.count == 2)
        #expect(trimmed.segments.map(\.count).reduce(0, +) < 160)
    }

    @Test func escapesTheTitleAndMakesASafeFileName() throws {
        let start = Date()
        let hike = Hike(title: "Tom & Jerry's <loop>/\"east\"", startedAt: start, endedAt: start, seconds: 0, segments: [walk(points: 5)])
        let xml = try GPXExport.data(for: hike, options: .init(trimEnds: false))
        #expect(try GPXReader.read(xml).name == "Tom & Jerry's <loop>/\"east\"")
        let name = GPXExport.fileName(for: hike)
        #expect(name.hasSuffix(".gpx") && !name.contains("/") && !name.contains("\""))
        #expect(GPXExport.fileName(for: Hike(title: "  ", startedAt: start, endedAt: start, seconds: 0, segments: [])) == "Hike.gpx")
    }

    @MainActor @Test func defaultsAreTimeElevationAndTrimOn() {
        let options = GPXExport.Options()
        #expect(options.includeTimeAndElevation && options.trimEnds)
        #expect(GPXExport.endTrim == 200 && HikingModel.privacyTrim == GPXExport.endTrim)
    }

    @Test func anExportedHikeCanBeImportedBack() throws {
        let hike = recordedHike(points: 120)
        let xml = try GPXExport.data(for: hike)
        let result = try GPXImport.trail(from: xml, fallbackName: "x", now: Date())
        #expect(result.trail.name == "Lake Blanche")
        #expect(result.hasElevation)
    }
}

// MARK: Statistics

@MainActor
@Suite struct HikeStatisticsTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    private let calendar = HikeStatisticsTests.calendar

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// A hike of about `points * 10` m, climbing `rise` m per point, taking `seconds`.
    private func hike(_ date: Date, points: Int = 101, rise: Double = 1, seconds: Double = 3600, start: Double = 1500) -> Hike {
        Hike(
            title: "Hike \(date.timeIntervalSince1970)", startedAt: date, endedAt: date.addingTimeInterval(seconds), seconds: seconds,
            segments: [walk(points: points, step: 10, rise: rise, from: GeoPoint(latitude: 40.25, longitude: -111.63, elevation: start))]
        )
    }

    // Wednesday 14 Oct 2026.
    private var now: Date { day(2026, 10, 14, 12) }

    @Test func totalsForTheMonth() {
        let hikes = [
            hike(day(2026, 10, 2), points: 101), hike(day(2026, 10, 9), points: 201, rise: 2, seconds: 7200),
            hike(day(2026, 9, 30)), hike(day(2025, 10, 5)),
        ]
        let stats = HikeStatistics(hikes: hikes, period: .month, now: now, calendar: calendar)
        #expect(stats.totals.hikes == 2)
        #expect(abs(stats.totals.metres - (1000 + 2000)) < 20)
        #expect(abs(stats.totals.climb - (100 + 400)) < 8)
        #expect(stats.totals.seconds == 10800)
        #expect(stats.totals.averageSeconds == 5400)
        #expect(abs(stats.totals.averageMetres - 1500) < 10)
        #expect(stats.hikes.first?.startedAt == day(2026, 10, 9))
    }

    @Test func weekRunsFromMonday() {
        let hikes = [hike(day(2026, 10, 12)), hike(day(2026, 10, 14, 8)), hike(day(2026, 10, 11, 20)), hike(day(2026, 10, 19))]
        let stats = HikeStatistics(hikes: hikes, period: .week, now: now, calendar: calendar)
        #expect(stats.totals.hikes == 2)
        #expect(stats.bars.count == 7)
        #expect(stats.bars.map(\.hikes) == [1, 0, 1, 0, 0, 0, 0])
    }

    @Test func yearAndAllTime() {
        let hikes = [hike(day(2026, 1, 3)), hike(day(2026, 6, 3)), hike(day(2026, 6, 20)), hike(day(2025, 12, 31)), hike(day(2023, 3, 1))]
        let year = HikeStatistics(hikes: hikes, period: .year, now: now, calendar: calendar)
        #expect(year.totals.hikes == 3)
        #expect(year.bars.count == 12)
        #expect(year.bars[5].hikes == 2)
        #expect(year.bars[0].label == "Jan")
        let all = HikeStatistics(hikes: hikes, period: .allTime, now: now, calendar: calendar)
        #expect(all.totals.hikes == 5)
        #expect(all.bars.first?.hikes == 1)
        #expect(all.bars.map(\.hikes).reduce(0, +) == 5)
        #expect(all.bars.count == 44)
    }

    @Test func monthHasWeeklyBars() {
        let stats = HikeStatistics(hikes: [hike(day(2026, 10, 2)), hike(day(2026, 10, 14))], period: .month, now: now, calendar: calendar)
        #expect(stats.bars.count == 5)
        #expect(stats.bars.map(\.hikes).reduce(0, +) == 2)
    }

    @Test func noHikesGivesZerosNotNaN() {
        let stats = HikeStatistics(hikes: [], period: .month, now: now, calendar: calendar)
        #expect(stats.totals == HikeStatistics.Totals())
        #expect(stats.totals.averageMetres == 0 && stats.totals.averageSeconds == 0 && stats.totals.averageClimb == 0)
        #expect(stats.bars.allSatisfy { $0.hikes == 0 })
        #expect(HikeStatistics(hikes: [], period: .allTime, now: now, calendar: calendar).bars.isEmpty)
        #expect(stats.bests.longest == nil && stats.bests.streakWeeks == 0 && stats.bests.busiestMonth == nil)
    }

    @Test func personalBestsLookAtEveryHike() {
        let longest = hike(day(2025, 7, 1), points: 301, rise: 0)
        let climber = hike(day(2025, 8, 1), points: 101, rise: 5, seconds: 1000)
        let highest = hike(day(2026, 9, 1), points: 51, rise: 1, seconds: 100, start: 4000)
        let slow = hike(day(2026, 9, 2), points: 51, rise: 0, seconds: 30_000)
        let stats = HikeStatistics(hikes: [longest, climber, highest, slow], period: .week, now: now, calendar: calendar)
        #expect(stats.totals.hikes == 0)
        #expect(stats.bests.longest == longest)
        #expect(stats.bests.mostClimb == climber)
        #expect(stats.bests.highest == highest)
        #expect(stats.bests.longestTime == slow)
        #expect(stats.bests.busiestMonth?.count == 2)
        #expect(stats.bests.busiestMonth?.start == day(2026, 9, 1, 0))
    }

    @Test func streakCountsConsecutiveWeeks() {
        let dates = [day(2026, 10, 1), day(2026, 10, 8), day(2026, 10, 12), day(2026, 10, 13), day(2026, 9, 1), day(2026, 9, 8), day(2026, 9, 15), day(2026, 9, 22)]
        #expect(HikeStatistics.streak(dates, calendar: calendar) == 7)
        #expect(HikeStatistics.streak(Array(dates.suffix(4)), calendar: calendar) == 4)
        #expect(HikeStatistics.streak([], calendar: calendar) == 0)
        #expect(HikeStatistics.streak([day(2026, 1, 1), day(2026, 3, 1)], calendar: calendar) == 1)
        // A year boundary is still consecutive.
        #expect(HikeStatistics.streak([day(2025, 12, 29), day(2026, 1, 5)], calendar: calendar) == 2)
    }

    @Test func importedTrailsNeverCount() async throws {
        let store = MemoryBlobStore()
        let log = HikeLog(store: store, rootKey: try ContentRootKey.generate())
        let imported = try GPXImport.trail(from: data(garminGPX), fallbackName: "x", now: now)
        try await log.save(imported.trail)
        try await log.save(hike(day(2026, 10, 3)))
        let model = await HikingModel(log: log, location: nil, units: HikeUnits(metric: true))
        await model.load()
        let stats = await model.statistics(for: .allTime, now: now, calendar: calendar)
        #expect(stats.totals.hikes == 1)
        #expect(await model.saved.count == 1)
    }

    @Test func periodStartsOnMonthAndNamesItself() {
        #expect(HikeStatistics.Period.allCases.map(\.rawValue) == ["Week", "Month", "Year", "All time"])
        #expect(HikeStatistics(hikes: [], period: .allTime, now: now, calendar: calendar).periodName == "in all")
    }
}

// MARK: Groups and sealing

@MainActor
@Suite struct HikeGroupTests {
    private func makeModel(_ store: MemoryBlobStore = MemoryBlobStore(), key: ContentRootKey? = nil) throws -> (HikingModel, HikeLog) {
        let log = HikeLog(store: store, rootKey: try key ?? ContentRootKey.generate())
        return (HikingModel(log: log, location: nil, units: HikeUnits(metric: true)), log)
    }

    private func importTrail(_ model: HikingModel, name: String, group: UUID? = nil) async throws {
        let result = try GPXImport.trail(from: data(garminGPX), fallbackName: name, now: Date())
        _ = await model.saveImported(result, name: name, groupID: group)
    }

    @Test func namesAreTrimmedAndCappedAtForty() {
        #expect(HikeGroup.clean("  Wasatch  ") == "Wasatch")
        #expect(HikeGroup.clean("   ") == nil)
        #expect(HikeGroup.clean(String(repeating: "x", count: 90))?.count == 40)
    }

    @Test func createRenameAndKeepAcrossReopening() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let (model, _) = try makeModel(store, key: key)
        await model.load()
        let group = try #require(await model.createGroup(named: " Fall colours "))
        #expect(group.name == "Fall colours")
        #expect(await model.createGroup(named: "  ") == nil)
        await model.renameGroup(group, to: "Autumn")
        let (reopened, _) = try self.makeModel(store, key: key)
        await reopened.load()
        #expect(reopened.groups.map(\.name) == ["Autumn"])
    }

    @Test func aTrailLivesInOneGroup() async throws {
        let (model, _) = try makeModel()
        await model.load()
        let a = try #require(await model.createGroup(named: "A"))
        let b = try #require(await model.createGroup(named: "B"))
        try await importTrail(model, name: "Olympus", group: a.id)
        let trail = try #require(model.saved.first)
        #expect(model.savedTrails(in: a.id).count == 1)
        await model.move(trail, to: b.id)
        #expect(model.savedTrails(in: a.id).isEmpty)
        #expect(model.savedTrails(in: b.id).count == 1)
        #expect(model.savedTrails(in: nil).count == 1)
        await model.move(trail, to: nil)
        #expect(model.saved.first?.groupID == nil)
        await model.move(trail, to: UUID())
        #expect(model.saved.first?.groupID == nil)
    }

    @Test func deletingAGroupMovesItsTrailsToAllSaved() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let (model, _) = try makeModel(store, key: key)
        await model.load()
        let group = try #require(await model.createGroup(named: "Wasatch"))
        try await importTrail(model, name: "One", group: group.id)
        try await importTrail(model, name: "Two", group: group.id)
        await model.deleteGroup(group)
        #expect(model.groups.isEmpty)
        #expect(model.saved.count == 2)
        #expect(model.saved.allSatisfy { $0.groupID == nil })
        let (reopened, _) = try self.makeModel(store, key: key)
        await reopened.load()
        #expect(reopened.groups.isEmpty)
        #expect(reopened.saved.count == 2)
        #expect(reopened.saved.allSatisfy { $0.groupID == nil })
    }

    @Test func importedTrailsAndGroupsAreSealedAndKeptOffTheDisk() async throws {
        let store = MemoryBlobStore()
        let (model, _) = try makeModel(store)
        await model.load()
        let group = try #require(await model.createGroup(named: "Secret hideout group"))
        try await importTrail(model, name: "Grandma's house", group: group.id)
        #expect(store.all.keys.contains { $0.hasSuffix(HikeLog.groupsSuffix) })
        for (_, blob) in store.all {
            let text = String(decoding: blob, as: UTF8.self)
            #expect(!text.contains("Secret hideout") && !text.contains("Grandma") && !text.contains("40.69"))
        }
        #expect(HikeLog.sealedPurposes[HikeLog.groupsSuffix] == .hikeGroups)
    }

    @Test func importingDoesNotSaveUntilSaved() async throws {
        let (model, log) = try makeModel()
        await model.load()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Olympus Loop.gpx")
        try data(oldGPX).write(to: url)
        let preview = try await model.prepareImport(from: url)
        #expect(await log.savedTrails().isEmpty)
        #expect(await model.saveImported(preview, name: "My name", groupID: nil))
        #expect(await log.savedTrails().first?.name == "My name")
        #expect(model.notice == "Saved My name")
    }

    @Test func anImportedTrailNeverLooksUpElevationOnline() async throws {
        let http = FakeHTTP()
        let log = HikeLog(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        let model = HikingModel(log: log, elevation: OpenMeteoElevation(http: http), location: nil, units: HikeUnits(metric: true))
        await model.load()
        let result = try GPXImport.trail(from: data(noElevationGPX), fallbackName: "x", now: Date())
        await model.lookUpProfile(result.trail)
        #expect(http.requests.isEmpty)
    }

    @Test func exportWritesAFileThatReadsBack() throws {
        let (model, _) = try makeModel()
        let url = try model.exportFile(for: recordedHike(), options: .init())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "Lake Blanche.gpx")
        #expect(try GPXReader.read(Data(contentsOf: url)).segments.first?.isEmpty == false)
    }

    @Test func unreadableHikesAreCounted() async throws {
        let store = MemoryBlobStore()
        let (model, log) = try makeModel(store)
        try await log.save(recordedHike())
        try store.write(Data("junk".utf8), as: UUID().uuidString.lowercased() + HikeLog.hikeSuffix)
        await model.load()
        #expect(model.hikes.count == 1)
        #expect(model.unreadableHikes == 1)
    }
}
