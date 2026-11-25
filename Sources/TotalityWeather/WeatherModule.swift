import Foundation
import TotalityCore

/// Weather's entry in the registry. It meets other modules only here: refresh, search, and the day's
/// forecast that the Calendar shows beside a day (issue 203, section 5).
public struct WeatherModule: ContentHandler {
    public let module = ModuleID.weather
    public let kinds: Set<ContentKind> = [.weatherPlaces]
    private let book: WeatherPlaceBook?
    private let cache: ForecastCache?
    private let units: @Sendable () -> WeatherUnits
    private let refresh: @Sendable () async -> Void

    /// `refresh` brings Weather up to date, quietly. `units` is the person's choice of °F or °C.
    public init(
        book: WeatherPlaceBook?, cache: ForecastCache?,
        units: @escaping @Sendable () -> WeatherUnits = { WeatherUnits(locale: .autoupdatingCurrent) },
        refresh: @escaping @Sendable () async -> Void = {}
    ) {
        self.book = book
        self.cache = cache
        self.units = units
        self.refresh = refresh
    }
}

/// The app keeps Weather fresh before it's opened, through `AppRefresh`.
extension WeatherModule: ModuleRefresher {
    public func refreshAhead() async {
        await refresh()
    }
}

/// Finds a saved place by name. Reads only what's sealed on this device; nothing searched for is sent.
extension WeatherModule: ModuleSearcher {
    public func search(_ query: String) async throws -> [SearchHit] {
        let terms = SearchText.terms(in: query)
        guard let book, !terms.isEmpty else { return [] }
        let places = await book.load().places
        try Task.checkCancellation()
        let units = units()
        var hits: [SearchHit] = []
        for place in places {
            let text = "\(place.name) \(place.region)"
            guard terms.allSatisfy({ SearchText.find($0, in: text) != nil }) else { continue }
            var detail = place.region
            if let cached = await cache?.read(place.id.uuidString) {
                detail = "\(units.temp(cached.forecast.now.temperature)) \(cached.forecast.now.condition.name)"
            }
            hits.append(SearchHit(module: .weather, itemID: place.id.uuidString, title: place.name, detail: detail.isEmpty ? nil : detail))
        }
        return hits
    }
}

/// A day's forecast for the Calendar, from the last forecast on the device: where the person is if it's
/// shown, else their first saved place. Asking never fetches, so nothing is sent.
extension WeatherModule: ForecastProvider {
    public func forecast(on date: Date) async -> DayForecast? {
        guard let cache else { return nil }
        var cached = await cache.read(ForecastCache.here)
        if cached == nil, let first = await book?.load().places.first {
            cached = await cache.read(first.id.uuidString)
        }
        guard let cached else { return nil }
        return Self.day(cached, on: date, units: units())
    }

    static func day(_ cached: CachedForecast, on date: Date, units: WeatherUnits) -> DayForecast? {
        let forecast = cached.forecast
        // The day the person means, in their own time, matched to the place's day of the same date.
        let wanted = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let day = forecast.days.first(where: { forecast.calendar.dateComponents([.year, .month, .day], from: $0.date) == wanted }) else { return nil }
        let chance = Int(day.chance.rounded())
        return DayForecast(
            day: day.date, place: cached.name, high: units.degrees(day.high), low: units.degrees(day.low),
            unit: units.temperature.symbol, conditions: day.condition.name, systemImage: day.condition.systemImage(),
            chance: chance >= 10 ? chance : nil
        )
    }
}
