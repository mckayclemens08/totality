import Foundation

/// The one line about what's coming, such as "Snow likely after 7 pm", with a quieter line under it such as
/// "About 1 inch overnight. Dry until then." Minute-by-minute rain is used where the source has it.
public struct NextHour: Equatable, Sendable {
    public let headline: String
    public let detail: String?
    /// Whether rain or snow is on its way, so the screen can draw it with the rain icon.
    public let isWet: Bool
    public let isSnow: Bool

    /// Rain this light, in mm an hour, is too little to mention.
    static let wetEnough = 0.1
    /// A chance this high is "likely"; from `possible` up it's "possible".
    static let likely = 50.0
    static let possible = 30.0
    /// How far ahead the line looks.
    static let lookAhead = 12

    public static func summary(of forecast: Forecast, at date: Date, units: WeatherUnits) -> NextHour {
        let zone = forecast.zone
        let hours = forecast.hours(from: date, count: lookAhead + 1)

        // Falling now: say when it stops, from the quarter hours if there are any.
        let upcomingMinutes = forecast.minutes.filter { $0.start.addingTimeInterval(15 * 60) > date }
        let fallingNow = forecast.now.condition.isWet && (forecast.now.precipitation >= wetEnough || (upcomingMinutes.first?.precipitation ?? 0) >= wetEnough / 4)
        if fallingNow {
            let kind = forecast.now.condition.isSnow ? "Snow" : "Rain"
            if let dry = upcomingMinutes.first(where: { $0.precipitation < wetEnough / 4 }) {
                return NextHour(headline: "\(kind) stopping around \(WeatherClock.time(dry.start, in: zone))", detail: nil, isWet: true, isSnow: kind == "Snow")
            }
            if let dry = hours.dropFirst().first(where: { $0.chance < possible && $0.precipitation < wetEnough }) {
                return NextHour(headline: "\(kind) until about \(WeatherClock.hour(dry.time, in: zone))", detail: nil, isWet: true, isSnow: kind == "Snow")
            }
            return NextHour(headline: "\(kind) for the next few hours", detail: nil, isWet: true, isSnow: kind == "Snow")
        }

        // Starting within the hour, by the quarter hours.
        if let start = upcomingMinutes.prefix(4).first(where: { $0.precipitation >= wetEnough / 4 }) {
            let snow = hours.first?.condition.isSnow ?? false
            let kind = snow ? "Snow" : "Rain"
            let headline = start.start <= date ? "\(kind) starting now" : "\(kind) starting around \(WeatherClock.time(start.start, in: zone))"
            return NextHour(headline: headline, detail: nil, isWet: true, isSnow: snow)
        }

        // Later today, by the hours.
        if let first = hours.first(where: { $0.time > date.addingTimeInterval(-3600) && ($0.chance >= possible || $0.precipitation >= wetEnough * 5) }) {
            let snow = first.condition.isSnow || first.snowfall > 0
            let kind = snow ? "Snow" : "Rain"
            let word = first.chance >= likely || first.precipitation >= wetEnough * 5 ? "likely" : "possible"
            let when = first.time <= date ? "now" : "after \(WeatherClock.hour(first.time, in: zone))"
            let headline = word == "likely" ? "\(kind) likely \(when)" : "\(kind) possible \(when)"
            var parts: [String] = []
            let snowfall = hours.filter { $0.time >= first.time }.reduce(0) { $0 + $1.snowfall }
            if snow, snowfall >= 0.25 {
                let words = units.snow(snowfall)
                parts.append(words.prefix(1).uppercased() + words.dropFirst() + (Self.isOvernight(first.time, in: forecast.calendar) ? " overnight." : "."))
            }
            if first.time > date.addingTimeInterval(3600) { parts.append("Dry until then.") }
            return NextHour(headline: headline, detail: parts.isEmpty ? nil : parts.joined(separator: " "), isWet: true, isSnow: snow)
        }

        return NextHour(headline: "No rain or snow for the next \(lookAhead) hours", detail: nil, isWet: false, isSnow: false)
    }

    static func isOvernight(_ date: Date, in calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 18 || hour < 5
    }
}
