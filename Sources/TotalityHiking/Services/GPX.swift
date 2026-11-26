import Foundation

/// Why a GPX file couldn't be brought in, in words the screen can show.
public enum GPXError: Error, Equatable {
    /// Over 10 MB.
    case tooBig
    /// Not XML, not a `gpx` document, or one with a document type declaration, which is never read.
    case notGPX
    /// A GPX file with waypoints only, or fewer than two points in its tracks and routes.
    case noRoute(waypoints: Int)
    /// A trim that leaves nothing, on a hike too short to trim.
    case tooShortToTrim

    public var title: String {
        switch self {
        case .tooBig: "This file is too big"
        case .notGPX: "That isn't a GPX file"
        case .noRoute: "No route in this file"
        case .tooShortToTrim: "Too short to trim"
        }
    }

    public var detail: String {
        switch self {
        case .tooBig: "GPX files over 10 MB can't be brought in. Export a shorter track and try again."
        case .notGPX: "Totality reads GPS Exchange files that end in .gpx. This one couldn't be read as one."
        case .noRoute(let waypoints):
            waypoints > 0
                ? "This file has \(waypoints) waypoint\(waypoints == 1 ? "" : "s") but no track or route, so there's nothing to hike. Open a file with a recorded track."
                : "This file has no track or route, so there's nothing to hike. Open a file with a recorded track."
        case .tooShortToTrim: "This hike is too short to leave off its first and last 200 m. Turn that off to export it whole."
        }
    }
}

/// One point read from a GPX file, with the time it was recorded when the file says.
public struct GPXPoint: Equatable, Sendable {
    public var point: GeoPoint
    public var time: Date?
}

/// What a GPX file holds that Hiking uses: a name and its tracks (or, with none, its routes) as lines of
/// points. Waypoints are counted and left out.
public struct GPXFile: Equatable, Sendable {
    public var name: String?
    public var segments: [[GPXPoint]]
    public var waypoints: Int
}

/// Reads GPX safely (owner, 2026-11-26). The file is capped at 10 MB, a document type declaration is refused
/// outright so no entity can be defined or fetched, and the parser is told never to resolve external
/// entities. Nothing here touches the network.
public enum GPXReader {
    public static let maxBytes = 10 * 1024 * 1024

    public static func read(_ data: Data) throws -> GPXFile {
        guard data.count <= maxBytes else { throw GPXError.tooBig }
        for marker in ["<!DOCTYPE", "<!ENTITY"] {
            if data.range(of: Data(marker.utf8)) != nil { throw GPXError.notGPX }
            if data.range(of: Data(marker.lowercased().utf8)) != nil { throw GPXError.notGPX }
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let reader = Delegate()
        parser.delegate = reader
        guard parser.parse(), reader.sawRoot else { throw GPXError.notGPX }
        let lines = reader.tracks.isEmpty ? reader.routes : reader.tracks
        let usable = lines.filter { !$0.isEmpty }
        guard usable.reduce(0, { $0 + $1.count }) > 1 else { throw GPXError.noRoute(waypoints: reader.waypoints) }
        return GPXFile(name: reader.name, segments: usable, waypoints: reader.waypoints)
    }

    /// An ISO 8601 time with or without fractions of a second.
    static func parseTime(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawRoot = false
        var name: String?
        var tracks: [[GPXPoint]] = []
        var routes: [[GPXPoint]] = []
        var waypoints = 0

        private var path: [String] = []
        private var text = ""
        private var current: (lat: Double, lon: Double, ele: Double?, time: Date?)?
        private var segment: [GPXPoint] = []
        private var routeLine: [GPXPoint] = []

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if path.isEmpty {
                guard element == "gpx" else {
                    parser.abortParsing()
                    return
                }
                sawRoot = true
            }
            path.append(element)
            text = ""
            switch element {
            case "trkpt", "rtept":
                if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                    current = (lat, lon, nil, nil)
                } else {
                    current = nil
                }
            case "wpt":
                waypoints += 1
            case "trkseg":
                segment = []
            case "rte":
                routeLine = []
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // A name or a time is short. Text past this is not something Hiking reads.
            if text.count < 400 { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.dropLast().last
            switch element {
            case "ele":
                if current != nil, parent == "trkpt" || parent == "rtept", let height = Double(value), height.isFinite { current?.ele = height }
            case "time":
                if current != nil, parent == "trkpt" || parent == "rtept" { current?.time = GPXReader.parseTime(value) }
            case "name":
                // The file's name, or the first track's, or the first route's: whichever comes first.
                if name == nil, !value.isEmpty, parent == "metadata" || parent == "trk" || parent == "rte" {
                    name = String(value.prefix(120))
                }
            case "trkpt", "rtept":
                if let current {
                    let point = GeoPoint(latitude: current.lat, longitude: current.lon, elevation: current.ele)
                    if point.isValid {
                        let item = GPXPoint(point: point, time: current.time)
                        if element == "trkpt" { segment.append(item) } else { routeLine.append(item) }
                    }
                }
                current = nil
            case "trkseg":
                if !segment.isEmpty { tracks.append(segment) }
                segment = []
            case "rte":
                if !routeLine.isEmpty { routes.append(routeLine) }
                routeLine = []
            default:
                break
            }
            if !path.isEmpty { path.removeLast() }
            text = ""
        }
    }
}

/// Turns a GPX file into a trail to follow.
public enum GPXImport {
    /// What a GPX import hands back: the trail to save and whether the file had any heights.
    public struct Result: Equatable, Sendable {
        public var trail: Trail
        public var hasElevation: Bool
    }

    /// Joins every track in order into one line, thins it to a point about every 5 m, and keeps the heights
    /// the file has. With none, the trail still saves, and its screen says "No elevation in this file".
    public static func trail(from data: Data, fallbackName: String, now: Date, groupID: UUID? = nil, id: UUID = UUID()) throws -> Result {
        let file = try GPXReader.read(data)
        let joined = file.segments.flatMap { $0.map(\.point) }
        let line = GeoLine.thinned(joined, spacing: TrackBuilder.spacing)
        let heights = GeoLine.sampled(line.filter { $0.elevation != nil }, count: 200).compactMap(\.elevation)
        let hasElevation = heights.count > 1
        let name = GPXImport.cleanName(file.name) ?? cleanName(fallbackName) ?? "Imported trail"
        let trail = Trail(
            id: Trail.importedPrefix + id.uuidString.lowercased(), name: name, lines: [line], kind: "GPX file",
            profile: hasElevation ? heights : nil, savedAt: now, groupID: groupID
        )
        return Result(trail: trail, hasElevation: hasElevation)
    }

    /// The file's name without ".gpx", trimmed, or nil if nothing is left.
    public static func cleanName(_ name: String?) -> String? {
        guard var name = name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if name.lowercased().hasSuffix(".gpx") { name = String(name.dropLast(4)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(120))
    }

    /// Reads a file from Files or a share sheet, refusing one over the size cap before it is read.
    public static func read(contentsOf url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= GPXReader.maxBytes else { throw GPXError.tooBig }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // One byte past the cap, so a file that grew or lied about its size is still caught.
        let data = try handle.read(upToCount: GPXReader.maxBytes + 1) ?? Data()
        guard data.count <= GPXReader.maxBytes else { throw GPXError.tooBig }
        return data
    }
}

/// Writes a recorded hike as GPX 1.1 for other hiking apps.
public enum GPXExport {
    /// How much of each end the trim leaves off, the same as a shared picture.
    public static let endTrim = 200.0

    public struct Options: Equatable, Sendable {
        /// Times and elevations in each point. On by default.
        public var includeTimeAndElevation = true
        /// Leaves off the first and last 200 m so the file doesn't show where the hike started, such as home.
        public var trimEnds = true

        public init(includeTimeAndElevation: Bool = true, trimEnds: Bool = true) {
            self.includeTimeAndElevation = includeTimeAndElevation
            self.trimEnds = trimEnds
        }
    }

    /// The hike's points, with the ends trimmed if asked, still in the stretches they were walked in.
    public static func segments(of hike: Hike, options: Options) throws -> [[GeoPoint]] {
        guard options.trimEnds else { return hike.segments.filter { !$0.isEmpty } }
        let flat = hike.points
        guard let range = GeoLine.trimmedRange(flat, by: endTrim) else { throw GPXError.tooShortToTrim }
        var result: [[GeoPoint]] = []
        var offset = 0
        for segment in hike.segments {
            let span = offset..<(offset + segment.count)
            let kept = span.clamped(to: range)
            if !kept.isEmpty { result.append(Array(segment[(kept.lowerBound - offset)..<(kept.upperBound - offset)])) }
            offset += segment.count
        }
        return result
    }

    /// Points carry no clock of their own in a hike, so each gets a time in proportion to how far along the
    /// whole hike it is, between when it started and when it ended.
    public static func data(for hike: Hike, options: Options = Options()) throws -> Data {
        let stretches = try segments(of: hike, options: options)
        let total = GeoLine.length(hike.points)
        let elapsed = max(0, hike.endedAt.timeIntervalSince(hike.startedAt))
        // Distance walked before each point of the whole hike, so a trimmed file keeps true times.
        var walked: [Double] = []
        var running = 0.0
        var previous: GeoPoint?
        for point in hike.points {
            if let previous { running += previous.distance(to: point) }
            walked.append(running)
            previous = point
        }
        var index: [GeoPoint: Double] = [:]
        for (point, along) in zip(hike.points, walked) where index[point] == nil { index[point] = along }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let title = escape(hike.title)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Totality" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><name>\(title)</name>
        """
        if options.includeTimeAndElevation { xml += "<time>\(stamp.string(from: hike.startedAt))</time>" }
        xml += "</metadata>\n<trk><name>\(title)</name>\n"
        for stretch in stretches {
            xml += "<trkseg>\n"
            for point in stretch {
                xml += "<trkpt lat=\"\(String(format: "%.6f", point.latitude))\" lon=\"\(String(format: "%.6f", point.longitude))\">"
                if options.includeTimeAndElevation {
                    if let height = point.elevation { xml += "<ele>\(String(format: "%.1f", height))</ele>" }
                    let fraction = total > 0 ? (index[point] ?? 0) / total : 0
                    xml += "<time>\(stamp.string(from: hike.startedAt.addingTimeInterval(elapsed * fraction)))</time>"
                }
                xml += "</trkpt>\n"
            }
            xml += "</trkseg>\n"
        }
        xml += "</trk>\n</gpx>\n"
        return Data(xml.utf8)
    }

    /// A safe file name, like "Lake Blanche.gpx".
    public static func fileName(for hike: Hike) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = hike.title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Hike" : String(cleaned.prefix(80))) + ".gpx"
    }

    /// How many points the file will hold, for "1,096 points".
    public static func pointCount(of hike: Hike, options: Options) -> Int {
        (try? segments(of: hike, options: options).reduce(0) { $0 + $1.count }) ?? 0
    }

    static func escape(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" })
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
