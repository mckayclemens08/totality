import Foundation

/// °F or °C, and mph or km/h. They start from the device's region and can be changed in Weather's
/// settings. The choice is kept on this device only: it says nothing about any place.
public struct WeatherUnits: Codable, Equatable, Sendable {
    public enum Temperature: String, Codable, Sendable, CaseIterable, Identifiable {
        case fahrenheit, celsius

        public var id: String { rawValue }
        public var symbol: String { self == .fahrenheit ? "°F" : "°C" }
    }

    public enum Speed: String, Codable, Sendable, CaseIterable, Identifiable {
        case mph, kmh

        public var id: String { rawValue }
        public var symbol: String { self == .mph ? "mph" : "km/h" }
    }

    public var temperature: Temperature
    public var speed: Speed

    public init(temperature: Temperature, speed: Speed) {
        self.temperature = temperature
        self.speed = speed
    }

    /// The region's own: the US uses °F and mph, the UK °C and mph, and everywhere else °C and km/h.
    public init(locale: Locale) {
        switch locale.measurementSystem {
        case .us: self.init(temperature: .fahrenheit, speed: .mph)
        case .uk: self.init(temperature: .celsius, speed: .mph)
        default:
            // A few places on the metric system still use °F.
            let fahrenheit = ["US", "LR", "MM", "BS", "BZ", "KY", "PW"].contains(locale.region?.identifier ?? "")
            self.init(temperature: fahrenheit ? .fahrenheit : .celsius, speed: .kmh)
        }
    }

    public static let defaultsKey = "weather.units"

    public static func stored(in defaults: UserDefaults, locale: Locale = .autoupdatingCurrent) -> WeatherUnits {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(WeatherUnits.self, from: $0) } ?? WeatherUnits(locale: locale)
    }

    public func store(in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Converting

    /// A temperature from °C, rounded, as a whole number.
    public func degrees(_ celsius: Double) -> Int {
        let value = temperature == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        // Round half away from zero, and never show "-0".
        let rounded = Int(value.rounded())
        return rounded == 0 ? 0 : rounded
    }

    /// Such as "41°".
    public func temp(_ celsius: Double) -> String { "\(degrees(celsius))°" }

    /// Such as "8 mph SE".
    public func wind(_ kmh: Double, from direction: Double?) -> String {
        let value = speed == .mph ? kmh / 1.609_344 : kmh
        let compass = direction.map { " " + Self.compass($0) } ?? ""
        return "\(Int(value.rounded())) \(speed.symbol)\(compass)"
    }

    /// An amount of snow, from cm: "about 1 inch" or "about 3 cm". Under half a unit is "a little".
    public func snow(_ centimetres: Double) -> String {
        if temperature == .fahrenheit {
            let inches = centimetres / 2.54
            guard inches >= 0.5 else { return "a little snow" }
            let whole = Int(inches.rounded())
            return "about \(whole) inch\(whole == 1 ? "" : "es")"
        }
        guard centimetres >= 0.5 else { return "a little snow" }
        return "about \(Int(centimetres.rounded())) cm"
    }

    /// The compass point the wind comes from, of eight.
    static func compass(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normal = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((normal / 45).rounded()) % 8]
    }
}

/// How times read on Weather's screens, in the place's own time zone: "7 pm", "5:04 pm".
enum WeatherClock {
    static func hour(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "h a"
        return formatter.string(from: date).lowercased()
    }

    static func time(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date).lowercased()
    }

    /// "Today", or a short weekday such as "Sat".
    static func day(_ date: Date, in zone: TimeZone, today: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(date, inSameDayAs: today) { return "Today" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    /// A day in full, such as "Saturday, November 29".
    static func longDay(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }
}
