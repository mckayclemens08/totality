import Foundation

/// A point on the map. Every forecast request rounds it to two decimal places, about 1 km, before it leaves
/// the iPhone (issue 203, section 4).
public struct Coordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Two decimal places, about 1 km: what's sent to a weather source.
    public var rough: Coordinate {
        Coordinate(latitude: (latitude * 100).rounded() / 100, longitude: (longitude * 100).rounded() / 100)
    }

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// Roughly the United States and its territories in the Pacific and Caribbean, where the National
    /// Weather Service has alerts. A point outside is never sent to it.
    var isInUnitedStates: Bool {
        let mainland = (24...50).contains(latitude) && (-125 ... -66).contains(longitude)
        let alaska = (51...72).contains(latitude) && (-180 ... -129).contains(longitude)
        let hawaii = (18...23).contains(latitude) && (-161 ... -154).contains(longitude)
        let puertoRico = (17...19).contains(latitude) && (-68 ... -64).contains(longitude)
        let guam = (13...21).contains(latitude) && (144...146).contains(longitude)
        return mainland || alaska || hawaii || puertoRico || guam
    }
}

/// One place's forecast, in metric units as the sources give it: °C, km/h and millimetres. The screens
/// change units when they draw. It's sealed on the device and never synced.
public struct Forecast: Codable, Equatable, Sendable {
    public struct Now: Codable, Equatable, Sendable {
        public var temperature: Double
        public var feelsLike: Double
        public var condition: WeatherCondition
        public var isDaylight: Bool
        /// km/h, and degrees the wind comes from.
        public var windSpeed: Double
        public var windDirection: Double?
        /// 0 to 100.
        public var humidity: Double
        public var uvIndex: Double?
        /// mm in the last hour or so.
        public var precipitation: Double
    }

    /// A quarter of an hour of rain or snow, where the source has it.
    public struct Minutes: Codable, Equatable, Sendable {
        public var start: Date
        /// mm in these 15 minutes.
        public var precipitation: Double
    }

    public struct Hour: Codable, Equatable, Sendable, Identifiable {
        public var time: Date
        public var temperature: Double
        public var condition: WeatherCondition
        public var isDaylight: Bool
        /// 0 to 100.
        public var chance: Double
        public var precipitation: Double
        /// cm of snow in this hour.
        public var snowfall: Double

        public var id: Date { time }
    }

    public struct Day: Codable, Equatable, Sendable, Identifiable {
        /// Midnight at the start of the day, in the place's own time.
        public var date: Date
        public var high: Double
        public var low: Double
        public var condition: WeatherCondition
        public var chance: Double
        public var sunrise: Date?
        public var sunset: Date?
        public var uvMax: Double?

        public var id: Date { date }
    }

    public var fetchedAt: Date
    /// The place's own time zone, so "7 pm" is the place's evening.
    public var timeZone: String
    public var now: Now
    public var minutes: [Minutes]
    public var hours: [Hour]
    public var days: [Day]
    public var alerts: [WeatherAlert]
    public var air: AirQuality?
    /// Who it came from, as the screen credits it: "Open-Meteo" or "Apple Weather".
    public var source: String

    public init(
        fetchedAt: Date, timeZone: String, now: Now, minutes: [Minutes] = [], hours: [Hour], days: [Day],
        alerts: [WeatherAlert] = [], air: AirQuality? = nil, source: String
    ) {
        self.fetchedAt = fetchedAt
        self.timeZone = timeZone
        self.now = now
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.alerts = alerts
        self.air = air
        self.source = source
    }

    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    /// A calendar in the place's own time zone.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The next `count` hours from the one holding `date`.
    public func hours(from date: Date, count: Int = 24) -> [Hour] {
        let start = date.addingTimeInterval(-3600)
        return Array(hours.filter { $0.time > start }.prefix(count))
    }

    /// The hours of one day, midnight to midnight in the place's own time.
    public func hours(on day: Day) -> [Hour] {
        let end = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date.addingTimeInterval(86_400)
        return hours.filter { $0.time >= day.date && $0.time < end }
    }

    /// Today, in the place's own time, or the first day there is.
    public func today(at date: Date) -> Day? {
        days.first { calendar.isDate($0.date, inSameDayAs: date) } ?? days.first
    }

    /// The days from today on.
    public func days(from date: Date) -> [Day] {
        let start = calendar.startOfDay(for: date)
        return days.filter { $0.date >= start }
    }

    /// Alerts not over yet.
    public func activeAlerts(at date: Date) -> [WeatherAlert] {
        alerts.filter { ($0.ends ?? .distantFuture) > date }
    }
}

/// A government warning, such as a Winter Storm Warning, as the national service gives it.
public struct WeatherAlert: Codable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable, Comparable {
        case minor, moderate, severe, extreme, unknown

        private var rank: Int {
            switch self {
            case .unknown: 0
            case .minor: 1
            case .moderate: 2
            case .severe: 3
            case .extreme: 4
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public var id: String
    /// Such as "Winter Storm Warning".
    public var event: String
    public var headline: String
    public var severity: Severity
    public var ends: Date?
    public var details: String
    /// Who issued it, such as "NWS Salt Lake City UT".
    public var issuer: String

    public init(id: String, event: String, headline: String, severity: Severity, ends: Date?, details: String, issuer: String) {
        self.id = id
        self.event = event
        self.headline = headline
        self.severity = severity
        self.ends = ends
        self.details = details
        self.issuer = issuer
    }
}

/// Air quality and pollen now, from Open-Meteo's air-quality service. Pollen is only measured in Europe.
public struct AirQuality: Codable, Equatable, Sendable {
    public struct Pollen: Codable, Equatable, Sendable {
        /// Such as "Grass".
        public var name: String
        /// Grains per cubic metre.
        public var grains: Double

        /// Low, moderate, high or very high, by the thresholds the European pollen services use.
        public var level: String {
            switch grains {
            case ..<10: "Low"
            case ..<50: "Moderate"
            case ..<200: "High"
            default: "Very high"
            }
        }
    }

    /// The US Air Quality Index, 0 to 500.
    public var usIndex: Int?
    /// PM2.5 in µg/m³.
    public var pm25: Double?
    public var pollen: [Pollen]

    public init(usIndex: Int?, pm25: Double?, pollen: [Pollen]) {
        self.usIndex = usIndex
        self.pm25 = pm25
        self.pollen = pollen
    }

    /// The US index's band, such as "Good".
    public var category: String? {
        guard let usIndex else { return nil }
        switch usIndex {
        case ...50: return "Good"
        case ...100: return "Moderate"
        case ...150: return "Unhealthy for some"
        case ...200: return "Unhealthy"
        case ...300: return "Very unhealthy"
        default: return "Hazardous"
        }
    }

    /// The pollen that's highest now, if any was measured.
    public var topPollen: Pollen? {
        pollen.filter { $0.grains > 0 }.max { $0.grains < $1.grains }
    }
}
