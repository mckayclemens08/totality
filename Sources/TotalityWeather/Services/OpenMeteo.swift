import Foundation

/// Open-Meteo's forecast, free with no key for non-commercial use, up to 10,000 calls a day (issue 203,
/// section 3). It must be credited (CC BY 4.0). It sees the rounded coordinate and the iPhone's IP address.
public struct OpenMeteoSource: ForecastSource {
    public static let sourceName = "Open-Meteo"
    public var name: String { Self.sourceName }
    public var attributionURL: URL { URL(string: "https://open-meteo.com/")! }

    private let http: any WeatherHTTP
    private let now: @Sendable () -> Date

    public init(http: any WeatherHTTP = URLSessionWeatherHTTP(), now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.now = now
    }

    static func url(for coordinate: Coordinate) -> URL {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,uv_index,is_day,precipitation"),
            .init(name: "minutely_15", value: "precipitation"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,precipitation,snowfall,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max"),
            .init(name: "forecast_days", value: "10"),
            .init(name: "forecast_minutely_15", value: "8"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        return parts.url!
    }

    public func forecast(at coordinate: Coordinate) async throws -> Forecast {
        let rough = coordinate.rough
        guard rough.isValid else { throw WeatherError.badAnswer }
        let data = try await http.get(Self.url(for: rough), headers: [:])
        return try Self.parse(data, fetchedAt: now())
    }

    struct Answer: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double?
            let relative_humidity_2m: Double?
            let weather_code: Int?
            let wind_speed_10m: Double?
            let wind_direction_10m: Double?
            let uv_index: Double?
            let is_day: Int?
            let precipitation: Double?
        }
        struct Minutely: Decodable {
            let time: [Double]
            let precipitation: [Double?]
        }
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let weather_code: [Int?]
            let precipitation_probability: [Double?]?
            let precipitation: [Double?]?
            let snowfall: [Double?]?
            let is_day: [Int?]?
        }
        struct Daily: Decodable {
            let time: [Double]
            let weather_code: [Int?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Double?]?
            let sunrise: [Double?]?
            let sunset: [Double?]?
            let uv_index_max: [Double?]?
        }
        let timezone: String
        let current: Current
        let minutely_15: Minutely?
        let hourly: Hourly
        let daily: Daily
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> Forecast {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw WeatherError.badAnswer }
        let current = answer.current
        func at<T>(_ list: [T?]?, _ index: Int) -> T? {
            guard let list, list.indices.contains(index) else { return nil }
            return list[index]
        }
        let now = Forecast.Now(
            temperature: current.temperature_2m,
            feelsLike: current.apparent_temperature ?? current.temperature_2m,
            condition: WeatherCondition(wmo: current.weather_code ?? 3),
            isDaylight: (current.is_day ?? 1) == 1,
            windSpeed: current.wind_speed_10m ?? 0,
            windDirection: current.wind_direction_10m,
            humidity: current.relative_humidity_2m ?? 0,
            uvIndex: current.uv_index,
            precipitation: current.precipitation ?? 0
        )
        let minutes: [Forecast.Minutes] = answer.minutely_15.map { block in
            block.time.indices.compactMap { index in
                guard let amount = at(block.precipitation, index) else { return nil }
                return Forecast.Minutes(start: Date(timeIntervalSince1970: block.time[index]), precipitation: amount)
            }
        } ?? []
        let hourly = answer.hourly
        let hours: [Forecast.Hour] = hourly.time.indices.compactMap { index in
            guard let temperature = at(hourly.temperature_2m, index) else { return nil }
            return Forecast.Hour(
                time: Date(timeIntervalSince1970: hourly.time[index]),
                temperature: temperature,
                condition: WeatherCondition(wmo: at(hourly.weather_code, index) ?? 3),
                isDaylight: (at(hourly.is_day, index) ?? 1) == 1,
                chance: at(hourly.precipitation_probability, index) ?? 0,
                precipitation: at(hourly.precipitation, index) ?? 0,
                snowfall: at(hourly.snowfall, index) ?? 0
            )
        }
        let daily = answer.daily
        let days: [Forecast.Day] = daily.time.indices.compactMap { index in
            guard let high = at(daily.temperature_2m_max, index), let low = at(daily.temperature_2m_min, index) else { return nil }
            return Forecast.Day(
                date: Date(timeIntervalSince1970: daily.time[index]),
                high: high, low: low,
                condition: WeatherCondition(wmo: at(daily.weather_code, index) ?? 3),
                chance: at(daily.precipitation_probability_max, index) ?? 0,
                sunrise: at(daily.sunrise, index).map(Date.init(timeIntervalSince1970:)),
                sunset: at(daily.sunset, index).map(Date.init(timeIntervalSince1970:)),
                uvMax: at(daily.uv_index_max, index)
            )
        }
        guard !hours.isEmpty, !days.isEmpty else { throw WeatherError.badAnswer }
        return Forecast(fetchedAt: fetchedAt, timeZone: answer.timezone, now: now, minutes: minutes, hours: hours, days: days, source: sourceName)
    }
}

/// Air quality and pollen now, from Open-Meteo's free air-quality service.
public struct AirQualitySource: Sendable {
    private let http: any WeatherHTTP

    public init(http: any WeatherHTTP = URLSessionWeatherHTTP()) {
        self.http = http
    }

    static let pollenNames: [(field: String, name: String)] = [
        ("alder_pollen", "Alder"), ("birch_pollen", "Birch"), ("grass_pollen", "Grass"),
        ("mugwort_pollen", "Mugwort"), ("olive_pollen", "Olive"), ("ragweed_pollen", "Ragweed"),
    ]

    static func url(for coordinate: Coordinate) -> URL {
        var parts = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        parts.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            .init(name: "current", value: (["us_aqi", "pm2_5"] + pollenNames.map(\.field)).joined(separator: ",")),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        return parts.url!
    }

    public func airQuality(at coordinate: Coordinate) async throws -> AirQuality {
        let data = try await http.get(Self.url(for: coordinate.rough), headers: [:])
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> AirQuality {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any] else { throw WeatherError.badAnswer }
        let pollen = pollenNames.compactMap { field, name in
            (current[field] as? NSNumber).map { AirQuality.Pollen(name: name, grains: $0.doubleValue) }
        }
        return AirQuality(
            usIndex: (current["us_aqi"] as? NSNumber)?.intValue,
            pm25: (current["pm2_5"] as? NSNumber)?.doubleValue,
            pollen: pollen
        )
    }
}

/// Open-Meteo's free city search, for adding a place. It sees the words typed, never where the person is.
public struct OpenMeteoPlaces: PlaceSearcher {
    private let http: any WeatherHTTP

    public init(http: any WeatherHTTP = URLSessionWeatherHTTP()) {
        self.http = http
    }

    static func url(for query: String) -> URL? {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: "10"),
            .init(name: "language", value: "en"),
            .init(name: "format", value: "json"),
        ]
        return parts.url
    }

    public func places(matching query: String) async throws -> [WeatherPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The service needs two letters or more.
        guard trimmed.count >= 2, let url = Self.url(for: trimmed) else { return [] }
        return try Self.parse(try await http.get(url, headers: [:]))
    }

    struct Answer: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
            let timezone: String?
        }
        let results: [Result]?
    }

    static func parse(_ data: Data) throws -> [WeatherPlace] {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw WeatherError.badAnswer }
        return (answer.results ?? []).map { result in
            let region = [result.admin1, result.country].compactMap { $0 }.filter { !$0.isEmpty && $0 != result.name }
            return WeatherPlace(
                name: result.name, region: region.joined(separator: ", "),
                coordinate: Coordinate(latitude: result.latitude, longitude: result.longitude), timeZone: result.timezone
            )
        }
    }
}
