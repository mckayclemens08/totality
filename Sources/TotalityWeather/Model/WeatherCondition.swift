import Foundation

/// The sky, in the few kinds a person tells apart. Each source's own codes come down to these.
public enum WeatherCondition: String, Codable, Sendable, CaseIterable {
    case clear, mostlyClear, partlyCloudy, cloudy, fog
    case drizzle, rain, heavyRain, freezingRain, sleet
    case snow, heavySnow, thunderstorm

    /// From the WMO weather code Open-Meteo gives (WMO 4677, as Open-Meteo documents it).
    public init(wmo code: Int) {
        switch code {
        case 0: self = .clear
        case 1: self = .mostlyClear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57, 66, 67: self = .freezingRain
        case 61, 63, 80, 81: self = .rain
        case 65, 82: self = .heavyRain
        case 71, 73, 77, 85: self = .snow
        case 75, 86: self = .heavySnow
        case 95, 96, 99: self = .thunderstorm
        default: self = .cloudy
        }
    }

    public var name: String {
        switch self {
        case .clear: "Clear"
        case .mostlyClear: "Mostly clear"
        case .partlyCloudy: "Partly cloudy"
        case .cloudy: "Cloudy"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .freezingRain: "Freezing rain"
        case .sleet: "Sleet"
        case .snow: "Snow"
        case .heavySnow: "Heavy snow"
        case .thunderstorm: "Thunderstorms"
        }
    }

    /// The SF Symbol, with the sun or the moon as the time of day has it.
    public func systemImage(isDaylight: Bool = true) -> String {
        switch self {
        case .clear: isDaylight ? "sun.max" : "moon.stars"
        case .mostlyClear: isDaylight ? "sun.min" : "moon"
        case .partlyCloudy: isDaylight ? "cloud.sun" : "cloud.moon"
        case .cloudy: "cloud"
        case .fog: "cloud.fog"
        case .drizzle: "cloud.drizzle"
        case .rain: "cloud.rain"
        case .heavyRain: "cloud.heavyrain"
        case .freezingRain, .sleet: "cloud.sleet"
        case .snow, .heavySnow: "cloud.snow"
        case .thunderstorm: "cloud.bolt.rain"
        }
    }

    public var isSnow: Bool { self == .snow || self == .heavySnow }

    /// Whether it means rain, snow or anything falling.
    public var isWet: Bool {
        switch self {
        case .clear, .mostlyClear, .partlyCloudy, .cloudy, .fog: false
        default: true
        }
    }
}
