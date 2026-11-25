import Foundation

/// One day's weather as another module sees it, like the Calendar beside a day's events: the high, the low,
/// the conditions and the chance of rain or snow. It comes from the person's places, so it stays in memory
/// on this device and is never stored or sent (issue 203).
public struct DayForecast: Sendable, Hashable {
    /// The day it's for, as the start of that day in the place's own time zone.
    public let day: Date
    /// Where it's for, such as "Provo".
    public let place: String
    /// In the person's own unit, already rounded, such as 47.
    public let high: Int
    public let low: Int
    /// The unit `high` and `low` are in, "°F" or "°C".
    public let unit: String
    /// Words such as "Partly cloudy".
    public let conditions: String
    /// An SF Symbol for the conditions.
    public let systemImage: String
    /// From 0 to 100, or nil when there's no chance worth showing.
    public let chance: Int?

    public init(day: Date, place: String, high: Int, low: Int, unit: String, conditions: String, systemImage: String, chance: Int?) {
        self.day = day
        self.place = place
        self.high = high
        self.low = low
        self.unit = unit
        self.conditions = conditions
        self.systemImage = systemImage
        self.chance = chance
    }

    /// What a chip beside a day says, such as "47° / 28° · 60%".
    public var short: String {
        let range = "\(high)° / \(low)°"
        guard let chance, chance >= 10 else { return range }
        return "\(range) · \(chance)%"
    }

    /// What VoiceOver says, such as "Provo: Partly cloudy, high 47, low 28, 60% chance of rain or snow".
    public var spoken: String {
        let base = "\(place): \(conditions), high \(high), low \(low)"
        guard let chance, chance >= 10 else { return base }
        return "\(base), \(chance)% chance of rain or snow"
    }
}

/// A module that can say what the weather will be on a day, from what it already has on the device. It never
/// fetches for the asker, so asking never sends anything anywhere (issue 203).
public protocol ForecastProvider: ContentHandler {
    /// The forecast for the day holding `date` at the person's first place, or nil when it isn't known,
    /// such as a day more than ten days off.
    func forecast(on date: Date) async -> DayForecast?
}

extension ModuleRegistry {
    /// Every module that can say what the weather will be.
    public var forecasters: [any ForecastProvider] {
        handlers.compactMap { $0 as? any ForecastProvider }
    }

    /// The first answer for the day holding `date`, or nil when no module knows.
    public func forecast(on date: Date) async -> DayForecast? {
        for provider in forecasters {
            if let found = await provider.forecast(on: date) { return found }
        }
        return nil
    }
}
