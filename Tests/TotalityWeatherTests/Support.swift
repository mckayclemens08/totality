import Foundation
import TotalityCore
@testable import TotalityWeather

final class MemoryBlobStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    var all: [String: Data] { lock.withLock { blobs } }
}

/// Answers each request from a table, and remembers every URL asked for.
final class FakeHTTP: WeatherHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Data] = [:]
    private var asked: [URL] = []
    var failure: WeatherError?

    func answer(_ host: String, with json: String) { lock.withLock { answers[host] = Data(json.utf8) } }
    var requests: [URL] { lock.withLock { asked } }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        let (data, failure) = lock.withLock { () -> (Data?, WeatherError?) in
            asked.append(url)
            return (answers[url.host ?? ""], self.failure)
        }
        if let failure { throw failure }
        guard let data else { throw WeatherError.failed }
        return data
    }
}

/// A forecast source that counts its calls and gives the same forecast back.
final class FakeSource: ForecastSource, @unchecked Sendable {
    let name = "Open-Meteo"
    let attributionURL = URL(string: "https://open-meteo.com/")!
    private let lock = NSLock()
    private var calls: [Coordinate] = []
    var failure: WeatherError?
    var forecast: Forecast

    init(forecast: Forecast) { self.forecast = forecast }

    var asked: [Coordinate] { lock.withLock { calls } }

    func forecast(at coordinate: Coordinate) async throws -> Forecast {
        let (failure, forecast) = lock.withLock { () -> (WeatherError?, Forecast) in
            calls.append(coordinate)
            return (self.failure, self.forecast)
        }
        if let failure { throw failure }
        return forecast
    }
}

struct FakeSearcher: PlaceSearcher {
    var results: [WeatherPlace] = []
    func places(matching query: String) async throws -> [WeatherPlace] { results }
}

@MainActor
final class FakeLocation: WeatherLocating {
    var access: LocationAccess
    var spot: Coordinate?
    var askedToRead = 0

    init(access: LocationAccess, spot: Coordinate? = nil) {
        self.access = access
        self.spot = spot
    }

    func roughLocation() async -> Coordinate? {
        askedToRead += 1
        if access == .notAsked { access = .allowed }
        return access == .allowed ? spot?.rough : nil
    }

    func name(of coordinate: Coordinate) async -> String? { "Provo" }
}

final class FakeNotices: WeatherAlertNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    var titles: [String] { lock.withLock { sent } }
    func requestPermission() async -> Bool { true }
    func notify(title: String, body: String, id: String) async { lock.withLock { sent.append(title) } }
}

/// A fixed moment: Friday 2026-11-28 14:30 in Denver (21:30 UTC).
let friday = Date(timeIntervalSince1970: 1_795_901_400)
let denver = TimeZone(identifier: "America/Denver")!

func sampleForecast(at date: Date = friday, snowFrom hour: Int = 5, chance: Double = 60) -> Forecast {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = denver
    let start = calendar.date(bySettingHour: calendar.component(.hour, from: date), minute: 0, second: 0, of: date)!
    let hours = (0..<48).map { index -> Forecast.Hour in
        let wet = index >= hour && index < hour + 6
        return Forecast.Hour(
            time: start.addingTimeInterval(Double(index) * 3600), temperature: 5 - Double(index) * 0.5,
            condition: wet ? .snow : .partlyCloudy, isDaylight: index < 3, chance: wet ? chance : 10,
            precipitation: wet ? 0.6 : 0, snowfall: wet ? 0.5 : 0
        )
    }
    let midnight = calendar.startOfDay(for: date)
    let days = (0..<10).map { index in
        Forecast.Day(
            date: calendar.date(byAdding: .day, value: index, to: midnight)!, high: 8 - Double(index), low: -2 - Double(index),
            condition: index == 0 ? .snow : .cloudy, chance: index == 0 ? chance : 0,
            sunrise: nil, sunset: calendar.date(bySettingHour: 17, minute: 4, second: 0, of: midnight), uvMax: 2
        )
    }
    return Forecast(
        fetchedAt: date, timeZone: "America/Denver",
        now: .init(temperature: 5, feelsLike: 2, condition: .partlyCloudy, isDaylight: true, windSpeed: 13, windDirection: 135, humidity: 52, uvIndex: 2, precipitation: 0),
        hours: hours, days: days, source: "Open-Meteo"
    )
}

let provo = WeatherPlace(name: "Provo", region: "Utah, United States", coordinate: Coordinate(latitude: 40.2338, longitude: -111.6585), timeZone: "America/Denver")
let lisbon = WeatherPlace(name: "Lisbon", region: "Lisbon, Portugal", coordinate: Coordinate(latitude: 38.7167, longitude: -9.1333), timeZone: "Europe/Lisbon")
