#if canImport(WeatherKit) && canImport(CoreLocation)
import CoreLocation
import Foundation
import WeatherKit

/// Apple Weather, through WeatherKit: included with the Apple Developer Program the owner already pays for,
/// up to 500,000 calls a month (issue 203, section 3). The framework signs each request with the app's own
/// entitlement, so no key is stored anywhere. It's used only when the build says the entitlement is on
/// (`TotalityWeatherKit` in Info.plist); otherwise Open-Meteo is.
@available(iOS 16, macOS 13, *)
public struct WeatherKitSource: ForecastSource {
    public static let sourceName = "Apple Weather"
    public var name: String { Self.sourceName }
    public var attributionURL: URL { URL(string: "https://weatherkit.apple.com/legal-attribution.html")! }

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func forecast(at coordinate: Coordinate) async throws -> Forecast {
        let rough = coordinate.rough
        let weather: Weather
        do {
            weather = try await WeatherKit.WeatherService.shared.weather(for: CLLocation(latitude: rough.latitude, longitude: rough.longitude))
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw WeatherError.offline
        } catch {
            throw WeatherError.failed
        }
        let current = weather.currentWeather
        let now = Forecast.Now(
            temperature: current.temperature.converted(to: .celsius).value,
            feelsLike: current.apparentTemperature.converted(to: .celsius).value,
            condition: Self.condition(current.condition.rawValue),
            isDaylight: current.isDaylight,
            windSpeed: current.wind.speed.converted(to: .kilometersPerHour).value,
            windDirection: current.wind.direction.converted(to: .degrees).value,
            humidity: current.humidity * 100,
            uvIndex: Double(current.uvIndex.value),
            precipitation: Self.millimetresPerHour(current.precipitationIntensity)
        )
        // Minute by minute, in quarters of an hour like Open-Meteo's.
        var minutes: [Forecast.Minutes] = []
        if let minuteForecast = weather.minuteForecast {
            let all = Array(minuteForecast.forecast)
            for start in stride(from: 0, to: min(all.count, 120), by: 15) {
                let quarter = all[start..<min(start + 15, all.count)]
                let perHour = quarter.map { Self.millimetresPerHour($0.precipitationIntensity) }.reduce(0, +) / Double(quarter.count)
                minutes.append(Forecast.Minutes(start: quarter.first!.date, precipitation: perHour / 4))
            }
        }
        let hours = weather.hourlyForecast.forecast.map { hour in
            let amount = hour.precipitationAmount.converted(to: .millimeters).value
            let snowy = hour.precipitation == .snow
            return Forecast.Hour(
                time: hour.date,
                temperature: hour.temperature.converted(to: .celsius).value,
                condition: Self.condition(hour.condition.rawValue),
                isDaylight: hour.isDaylight,
                chance: hour.precipitationChance * 100,
                precipitation: amount,
                // About 1 cm of snow for each mm of water.
                snowfall: snowy ? amount : 0
            )
        }
        let days = weather.dailyForecast.forecast.prefix(10).map { day in
            Forecast.Day(
                date: day.date,
                high: day.highTemperature.converted(to: .celsius).value,
                low: day.lowTemperature.converted(to: .celsius).value,
                condition: Self.condition(day.condition.rawValue),
                chance: day.precipitationChance * 100,
                sunrise: day.sun.sunrise, sunset: day.sun.sunset,
                uvMax: Double(day.uvIndex.value)
            )
        }
        let alerts = (weather.weatherAlerts ?? []).map { alert in
            TotalityWeather.WeatherAlert(
                id: alert.detailsURL.absoluteString, event: alert.summary, headline: alert.summary,
                severity: TotalityWeather.WeatherAlert.Severity(rawValue: String(describing: alert.severity).lowercased()) ?? .unknown,
                ends: alert.metadata.expirationDate, details: alert.region.map { "For \($0)." } ?? "", issuer: alert.source
            )
        }
        return Forecast(
            fetchedAt: self.now(), timeZone: TimeZone.current.identifier, now: now, minutes: minutes,
            hours: hours, days: Array(days), alerts: alerts, source: Self.sourceName
        )
    }

    static func millimetresPerHour(_ speed: Measurement<UnitSpeed>) -> Double {
        speed.converted(to: .metersPerSecond).value * 3_600_000
    }

    /// Apple's many conditions, by name, down to Totality's few.
    static func condition(_ name: String) -> WeatherCondition {
        switch name {
        case "clear", "hot", "frigid": .clear
        case "mostlyClear", "breezy", "windy": .mostlyClear
        case "partlyCloudy", "sunShowers", "sunFlurries": .partlyCloudy
        case "mostlyCloudy", "cloudy": .cloudy
        case "foggy", "haze", "smoky", "blowingDust": .fog
        case "drizzle": .drizzle
        case "rain": .rain
        case "heavyRain", "tropicalStorm", "hurricane": .heavyRain
        case "freezingRain", "freezingDrizzle": .freezingRain
        case "sleet", "wintryMix", "hail": .sleet
        case "snow", "flurries", "blowingSnow": .snow
        case "heavySnow", "blizzard": .heavySnow
        case "thunderstorms", "isolatedThunderstorms", "scatteredThunderstorms", "strongStorms": .thunderstorm
        default: .cloudy
        }
    }
}
#endif
