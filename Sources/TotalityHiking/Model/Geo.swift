import Foundation

/// A point on a trail or a track, with its height in metres when it's known.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var elevation: Double?

    public init(latitude: Double, longitude: Double, elevation: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
    }

    enum CodingKeys: String, CodingKey {
        case latitude = "a", longitude = "o", elevation = "e"
    }

    /// Two decimal places, about 1 km: what's sent to look for trails nearby (issue 240, section 3).
    public var rough: GeoPoint {
        GeoPoint(latitude: (latitude * 100).rounded() / 100, longitude: (longitude * 100).rounded() / 100)
    }

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// The distance to `other` along the ground, in metres.
    public func distance(to other: GeoPoint) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Sums and shapes of a line of points.
public enum GeoLine {
    /// The length of the line, in metres.
    public static func length(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// How much the line climbs, in metres. A rise counts only once it passes `threshold`, so the jitter of
    /// GPS and a 90 m elevation model doesn't add up to a climb that wasn't there.
    public static func climb(_ heights: [Double], threshold: Double = 3) -> Double {
        guard var anchor = heights.first else { return 0 }
        var total = 0.0
        for height in heights.dropFirst() {
            if height - anchor >= threshold {
                total += height - anchor
                anchor = height
            } else if height < anchor {
                anchor = height
            }
        }
        return total
    }

    /// Points no closer together than `spacing` metres, always keeping the first and the last.
    public static func thinned(_ points: [GeoPoint], spacing: Double) -> [GeoPoint] {
        guard let first = points.first, points.count > 2 else { return points }
        var kept = [first]
        for point in points.dropFirst().dropLast() where kept[kept.count - 1].distance(to: point) >= spacing {
            kept.append(point)
        }
        kept.append(points[points.count - 1])
        return kept
    }

    /// At most `count` points spread evenly along the line, for one elevation lookup.
    public static func sampled(_ points: [GeoPoint], count: Int) -> [GeoPoint] {
        guard points.count > count, count > 1 else { return points }
        let step = Double(points.count - 1) / Double(count - 1)
        return (0..<count).map { points[Int((Double($0) * step).rounded())] }
    }

    /// The line with the first and last `metres` cut off, so a picture of it doesn't show where it started
    /// or ended, which could be someone's home. A line too short to trim leaves nothing.
    public static func trimmed(_ points: [GeoPoint], by metres: Double) -> [GeoPoint] {
        guard metres > 0 else { return points }
        guard length(points) > metres * 2 + 1 else { return [] }
        func dropStart(_ line: [GeoPoint]) -> [GeoPoint] {
            var walked = 0.0
            for index in 1..<line.count {
                walked += line[index - 1].distance(to: line[index])
                if walked >= metres { return Array(line[index...]) }
            }
            return []
        }
        return Array(dropStart(Array(dropStart(points).reversed())).reversed())
    }

    /// The range of indexes left once `metres` is cut off each end, or nil when the line is too short to trim.
    public static func trimmedRange(_ points: [GeoPoint], by metres: Double) -> Range<Int>? {
        guard points.count > 1 else { return nil }
        guard metres > 0 else { return 0..<points.count }
        guard length(points) > metres * 2 + 1 else { return nil }
        var walked = 0.0
        var start = 0
        for index in 1..<points.count {
            walked += points[index - 1].distance(to: points[index])
            if walked >= metres {
                start = index
                break
            }
        }
        walked = 0
        var end = points.count - 1
        for index in stride(from: points.count - 2, through: 0, by: -1) {
            walked += points[index + 1].distance(to: points[index])
            if walked >= metres {
                end = index
                break
            }
        }
        return start <= end ? start..<(end + 1) : nil
    }

    /// The corners of the box around every point, or nil for no points.
    public static func bounds(_ points: [GeoPoint]) -> (south: Double, west: Double, north: Double, east: Double)? {
        guard let first = points.first else { return nil }
        var box = (south: first.latitude, west: first.longitude, north: first.latitude, east: first.longitude)
        for point in points {
            box.south = min(box.south, point.latitude)
            box.north = max(box.north, point.latitude)
            box.west = min(box.west, point.longitude)
            box.east = max(box.east, point.longitude)
        }
        return box
    }
}

/// How far, how high and how long, in the person's units.
public struct HikeUnits: Sendable, Equatable {
    public var metric: Bool

    public init(metric: Bool) {
        self.metric = metric
    }

    public init(locale: Locale) {
        metric = locale.measurementSystem != .us
    }

    public func distance(_ metres: Double) -> String {
        if metric {
            let km = metres / 1000
            return km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
        }
        let miles = metres / 1609.344
        return miles < 10 ? String(format: "%.1f mi", miles) : String(format: "%.0f mi", miles)
    }

    public func height(_ metres: Double) -> String {
        let value = metric ? metres : metres * 3.28084
        return Self.grouped(value) + (metric ? " m" : " ft")
    }

    public func climb(_ metres: Double) -> String { "+" + height(metres) }

    /// Minutes per kilometre or mile, like "15:50 /km", or a dash before there's enough to say.
    public func pace(seconds: TimeInterval, metres: Double) -> String {
        let unit = metric ? 1000.0 : 1609.344
        guard metres >= 50, seconds > 0 else { return "–" }
        let perUnit = Int((seconds / (metres / unit)).rounded())
        return String(format: "%d:%02d %@", perUnit / 60, perUnit % 60, metric ? "/km" : "/mi")
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// A short length of time, like "1 h 58 min" or "42 min".
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }
}
