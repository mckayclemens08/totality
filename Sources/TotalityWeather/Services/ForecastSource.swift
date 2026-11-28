import Foundation

/// Where forecasts come from, kept behind one small protocol so the source can be swapped (issue 203,
/// section 3). Each request goes straight from the iPhone to the source, with the coordinate already rounded.
public protocol ForecastSource: Sendable {
    /// Who the screen credits and the privacy line names, such as "Open-Meteo".
    var name: String { get }
    /// The page the screen links for the source's terms and data sources.
    var attributionURL: URL { get }
    func forecast(at coordinate: Coordinate) async throws -> Forecast
}

/// Tries the primary forecast source first (e.g. Apple WeatherKit) and automatically falls back
/// to the backup source (e.g. Open-Meteo) when the primary service refuses or fails non-offline.
public struct FallbackForecastSource: ForecastSource {
    public let primary: any ForecastSource
    public let fallback: any ForecastSource

    public var name: String { primary.name }
    public var attributionURL: URL { primary.attributionURL }

    public init(primary: any ForecastSource, fallback: any ForecastSource) {
        self.primary = primary
        self.fallback = fallback
    }

    public func forecast(at coordinate: Coordinate) async throws -> Forecast {
        do {
            return try await primary.forecast(at: coordinate)
        } catch let error as WeatherError where error == .offline {
            throw error
        } catch {
            return try await fallback.forecast(at: coordinate)
        }
    }
}

/// Finds a city by name, for adding a place.
public protocol PlaceSearcher: Sendable {
    func places(matching query: String) async throws -> [WeatherPlace]
}

/// Plain GET requests, so tests can stand in for the network.
public protocol WeatherHTTP: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

/// The real network, with nothing kept: no cookies, no cache and no stored credentials.
public struct URLSessionWeatherHTTP: WeatherHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(error.code) {
            throw WeatherError.offline
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw WeatherError.failed }
        return data
    }
}

/// A forecast with the extras that come from elsewhere: air quality and pollen from Open-Meteo, and, in the
/// United States, alerts from the National Weather Service. An extra that fails leaves the forecast as it is.
public struct WeatherService: Sendable {
    public let source: any ForecastSource
    let air: AirQualitySource?
    let alerts: AlertSource?

    public init(source: any ForecastSource, air: AirQualitySource?, alerts: AlertSource?) {
        self.source = source
        self.air = air
        self.alerts = alerts
    }

    /// Who gets a rough location for each forecast, for the privacy line.
    public var recipients: [String] {
        var names = [source.name]
        if air != nil, !names.contains(OpenMeteoSource.sourceName) { names.append(OpenMeteoSource.sourceName) }
        if alerts != nil { names.append(NWSAlerts.sourceName + " (US only)") }
        return names
    }

    public func forecast(at coordinate: Coordinate) async throws -> Forecast {
        let rough = coordinate.rough
        async let main = source.forecast(at: rough)
        async let airNow = try? await air?.airQuality(at: rough)
        async let warnings = warnings(at: rough)
        var forecast = try await main
        if let found = await airNow { forecast.air = found }
        // A source with its own alerts, like Apple Weather, keeps them unless the service has some.
        if let found = await warnings, !found.isEmpty || forecast.alerts.isEmpty { forecast.alerts = found }
        return forecast
    }

    /// Nil outside the United States, where nothing is sent to the National Weather Service, or when it failed.
    private func warnings(at rough: Coordinate) async -> [WeatherAlert]? {
        guard let alerts, rough.isInUnitedStates else { return nil }
        return try? await alerts.alerts(at: rough)
    }
}
