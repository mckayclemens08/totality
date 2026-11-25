import Foundation
import Observation
import TotalityCore

/// Weather's state: the saved places, where the person is if they allow it, and the last forecast for each.
/// What shows comes from the sealed cache at once; `refresher` brings it up to date quietly.
@MainActor
@Observable
public final class WeatherModel {
    public enum Phase: Equatable {
        case loading, ready, failed
    }

    /// One place on the screen: where the person is, or a saved place.
    public struct Shown: Identifiable, Equatable {
        public let key: String
        public let name: String
        public let isHere: Bool
        public let place: WeatherPlace?

        public var id: String { key }
    }

    /// How old a forecast may be before the automatic refresh fetches again. Keeps one person well inside
    /// the free limits: Open-Meteo's 10,000 calls a day and WeatherKit's 500,000 a month.
    public static let freshFor: TimeInterval = 15 * 60
    /// How many places are fetched at once.
    static let together = 3
    static let useLocationKey = "weather.useLocation"
    static let askedKey = "weather.askedForLocation"
    static let alertsKey = "weather.alerts"

    public private(set) var phase = Phase.loading
    public private(set) var places: [WeatherPlace] = []
    public private(set) var forecasts: [String: CachedForecast] = [:]
    /// Where the person is, rounded, in memory only.
    public private(set) var here: Coordinate?
    public private(set) var locationAccess: LocationAccess
    /// The place being looked at, by key.
    public var selected: String?
    /// A saved place asked for from search, opened next time the screen shows.
    public var requestedPlace: UUID?
    public var units: WeatherUnits {
        didSet { units.store(in: defaults) }
    }
    /// Whether a new severe alert for a place makes a notification on this iPhone.
    public var alertsOn: Bool {
        didSet { defaults.set(alertsOn, forKey: Self.alertsKey) }
    }
    public let refresher = Refresher()

    @ObservationIgnored private var book: WeatherPlaceBook?
    @ObservationIgnored private var cache: ForecastCache?
    @ObservationIgnored public let service: WeatherService
    @ObservationIgnored private let searcher: any PlaceSearcher
    @ObservationIgnored private let location: (any WeatherLocating)?
    @ObservationIgnored private let notices: (any WeatherAlertNotifying)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var placesRecord = WeatherPlaces()
    @ObservationIgnored private var forceNext = false
    @ObservationIgnored private var namedHere: (coordinate: Coordinate, name: String)?

    public init(
        book: WeatherPlaceBook?, cache: ForecastCache?, service: WeatherService, searcher: any PlaceSearcher,
        location: (any WeatherLocating)?, notices: (any WeatherAlertNotifying)? = nil,
        defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.book = book
        self.cache = cache
        self.service = service
        self.searcher = searcher
        self.location = location
        self.notices = notices
        self.defaults = defaults
        self.now = now
        units = WeatherUnits.stored(in: defaults)
        alertsOn = defaults.object(forKey: Self.alertsKey) as? Bool ?? false
        locationAccess = location?.access ?? .denied
        refresher.add("weather", limit: .seconds(40)) { [weak self] in
            await self?.fetch() ?? .done
        }
    }

    // MARK: What shows

    /// Whether to show where the person is: they allowed it and didn't turn it off here.
    public var usesLocation: Bool {
        locationAccess == .allowed && (defaults.object(forKey: Self.useLocationKey) as? Bool ?? true)
    }

    /// Where the person is first, if they allow it, then the saved places in their order.
    public var shown: [Shown] {
        var list: [Shown] = []
        if usesLocation {
            list.append(Shown(key: ForecastCache.here, name: forecasts[ForecastCache.here]?.name ?? "Current location", isHere: true, place: nil))
        }
        list += places.map { Shown(key: $0.id.uuidString, name: $0.name, isHere: false, place: $0) }
        return list
    }

    public var isEmpty: Bool { shown.isEmpty }

    /// The place being looked at, or the first.
    public var current: Shown? {
        shown.first { $0.key == selected } ?? shown.first
    }

    public func forecast(for shown: Shown) -> Forecast? {
        forecasts[shown.key]?.forecast
    }

    /// Whether Weather should ask for the location when it opens: only the first time, and only in front.
    public var shouldAskForLocation: Bool {
        location != nil && locationAccess == .notAsked && !defaults.bool(forKey: Self.askedKey)
    }

    /// The privacy line under the forecast. It says only what's literally true (rule 5).
    public var privacyLine: String {
        let recipients = Self.list(service.recipients)
        let naming = usesLocation ? " Apple names where you are from the same rough location." : ""
        return "Your places are end-to-end encrypted. To get a forecast, a rough location is sent to \(recipients).\(naming)"
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// The oldest forecast showing, for "Updated 25 min ago" and the offline line.
    public var updatedAt: Date? {
        shown.compactMap { forecasts[$0.key]?.forecast.fetchedAt }.min()
    }

    /// The line to show when the last refresh didn't work, in Weather's own words.
    public var problemLine: String? {
        guard let problem = refresher.problem else { return nil }
        if problem == Refresher.offlineLine {
            guard let updatedAt else { return "You're offline. Weather will show once you're back online." }
            return "You're offline. This forecast is from \(WeatherClock.time(updatedAt, in: .current))."
        }
        return problem
    }

    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        guard let first = shown.first else { return ModuleGlance(lines: ["Add a place to see its weather"], isQuiet: true) }
        guard let forecast = forecast(for: first) else { return ModuleGlance(lines: [first.name, "Getting the forecast"], isQuiet: true) }
        var lines = ["\(first.name) · \(units.temp(forecast.now.temperature)) \(forecast.now.condition.name)"]
        if let today = forecast.today(at: now()) {
            lines.append("H \(units.temp(today.high))  L \(units.temp(today.low))")
        }
        lines.append(NextHour.summary(of: forecast, at: now(), units: units).headline)
        return ModuleGlance(lines: lines)
    }

    // MARK: Loading

    /// Reads the saved places and the cached forecasts, so the screen shows at once.
    public func load() async {
        guard let book, let cache else {
            phase = .failed
            return
        }
        placesRecord = await book.load()
        places = placesRecord.places
        var found: [String: CachedForecast] = [:]
        for key in [ForecastCache.here] + places.map(\.id.uuidString) {
            if let cached = await cache.read(key) { found[key] = cached }
        }
        forecasts = found
        locationAccess = location?.access ?? .denied
        phase = .ready
    }

    /// Reads the places again, after a sync may have brought another device's.
    public func reload() async {
        guard let book, phase == .ready else { return }
        let stored = await book.load()
        guard stored != placesRecord else { return }
        placesRecord = WeatherPlaces.merged(stored, placesRecord)
        places = placesRecord.places
        for place in places where forecasts[place.id.uuidString] == nil {
            if let cached = await cache?.read(place.id.uuidString) { forecasts[place.id.uuidString] = cached }
        }
    }

    /// Lets go of the sealed stores, for a key change. Nothing is deleted.
    public func stopForKeyChange() async {
        await book?.close()
        await cache?.close()
        book = nil
        cache = nil
    }

    /// The person pulled down: fetch every place now, however fresh.
    public func pull() async {
        forceNext = true
        await refresher.refresh(.pulled)
    }

    // MARK: Fetching

    /// Every place together, a few at a time, so the source can't tell which one is being looked at. Fresh
    /// forecasts aren't fetched again unless the person pulled down.
    func fetch() async -> RefreshOutcome {
        guard phase == .ready, cache != nil else { return .done }
        let force = forceNext
        forceNext = false
        locationAccess = location?.access ?? .denied

        var targets: [(key: String, name: String, coordinate: Coordinate, timeZone: String?)] = []
        var moved = false
        if usesLocation, let location, let found = await location.roughLocation() {
            // Where the person is moved: that one has to be fetched again.
            moved = here != found
            here = found
            let name: String
            if let namedHere, namedHere.coordinate == found {
                name = namedHere.name
            } else {
                name = await location.name(of: found) ?? "Current location"
                namedHere = (found, name)
            }
            targets.append((ForecastCache.here, name, found, nil))
        }
        targets += places.map { ($0.id.uuidString, $0.name, $0.coordinate, $0.timeZone) }
        guard !targets.isEmpty else { return .done }

        let date = now()
        let stale = targets.contains { target in
            guard let cached = forecasts[target.key] else { return true }
            return date.timeIntervalSince(cached.forecast.fetchedAt) >= Self.freshFor || cached.name != target.name
        }
        guard force || stale || moved else { return .done }

        var results: [String: Result<Forecast, Error>] = [:]
        for batch in stride(from: 0, to: targets.count, by: Self.together).map({ Array(targets[$0..<min($0 + Self.together, targets.count)]) }) {
            await withTaskGroup(of: (String, Result<Forecast, Error>).self) { group in
                for target in batch {
                    group.addTask { [service] in
                        do {
                            var forecast = try await service.forecast(at: target.coordinate)
                            if let zone = target.timeZone, TimeZone(identifier: zone) != nil, forecast.source != OpenMeteoSource.sourceName {
                                forecast.timeZone = zone
                            }
                            return (target.key, .success(forecast))
                        } catch {
                            return (target.key, .failure(error))
                        }
                    }
                }
                for await (key, result) in group { results[key] = result }
            }
        }

        var failures: [Error] = []
        var fresh: [(place: String, alert: WeatherAlert)] = []
        for target in targets {
            switch results[target.key] {
            case .success(let forecast):
                let cached = CachedForecast(name: target.name, forecast: forecast)
                forecasts[target.key] = cached
                try? await cache?.write(cached, for: target.key)
                fresh += forecast.activeAlerts(at: date).map { (target.name, $0) }
            case .failure(let error):
                failures.append(error)
            case nil:
                break
            }
        }
        await cache?.keepOnly(Set(targets.map(\.key)))
        await announce(fresh, at: date)

        guard !failures.isEmpty else { return .done }
        if failures.contains(where: { ($0 as? WeatherError) == .offline }) { return .offline }
        return .failed("\(service.source.name) didn't answer. Try again in a minute.")
    }

    private func announce(_ alerts: [(place: String, alert: WeatherAlert)], at date: Date) async {
        guard alertsOn, let notices else { return }
        var seen = Set(defaults.stringArray(forKey: AnnouncedAlerts.defaultsKey) ?? [])
        for item in AnnouncedAlerts.toAnnounce(alerts, seen: seen, at: date) {
            await notices.notify(title: "\(item.alert.event) for \(item.place)", body: item.alert.headline, id: item.alert.id)
            seen.insert(AnnouncedAlerts.mark(item.alert.id))
        }
        defaults.set(Array(seen.sorted().suffix(200)), forKey: AnnouncedAlerts.defaultsKey)
    }

    // MARK: Changing

    /// Asks for the location if it hasn't been asked, then shows the weather where the person is.
    public func useMyLocation() async {
        defaults.set(true, forKey: Self.askedKey)
        defaults.set(true, forKey: Self.useLocationKey)
        guard let location else { return }
        _ = await location.roughLocation()
        locationAccess = location.access
        if usesLocation { selected = ForecastCache.here }
        await pull()
    }

    /// Shows only the saved places, without asking iOS to stop.
    public func stopUsingLocation() {
        defaults.set(false, forKey: Self.useLocationKey)
        here = nil
        namedHere = nil
        forecasts[ForecastCache.here] = nil
        locationAccess = location?.access ?? .denied
        if selected == ForecastCache.here { selected = nil }
        Task { await cache?.keepOnly(Set(places.map(\.id.uuidString))) }
    }

    /// Remembers the location was asked about, when the person says not now.
    public func notNowForLocation() {
        defaults.set(true, forKey: Self.askedKey)
    }

    public func search(_ query: String) async throws -> [WeatherPlace] {
        try await searcher.places(matching: query)
    }

    @discardableResult
    public func add(_ place: WeatherPlace) async -> Bool {
        let added = placesRecord.add(place, at: now())
        guard await keep() else { return false }
        selected = added.id.uuidString
        await pull()
        return true
    }

    public func remove(_ id: UUID) async {
        placesRecord.remove(id, at: now())
        _ = await keep()
        forecasts[id.uuidString] = nil
        if selected == id.uuidString { selected = nil }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var ids = places.map(\.id)
        let moving = source.sorted().map { ids[$0] }
        let before = ids[..<min(destination, ids.count)].filter { !moving.contains($0) }
        ids = Array(before) + moving + ids.filter { !moving.contains($0) && !before.contains($0) }
        placesRecord.reorder(ids, at: now())
        _ = await keep()
    }

    private func keep() async -> Bool {
        guard let book else { return false }
        do {
            placesRecord = try await book.add(placesRecord)
            places = placesRecord.places
            return true
        } catch {
            places = placesRecord.places
            return false
        }
    }

    /// Turns alerts on, asking iOS first. Stays off if notifications aren't allowed.
    public func setAlerts(_ on: Bool) async {
        guard on else {
            alertsOn = false
            return
        }
        alertsOn = await notices?.requestPermission() ?? false
    }

    /// Opens a place asked for from search.
    public func openRequested() {
        guard let requestedPlace else { return }
        self.requestedPlace = nil
        if places.contains(where: { $0.id == requestedPlace }) { selected = requestedPlace.uuidString }
    }
}
