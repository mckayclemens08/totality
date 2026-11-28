import Foundation
import Testing
import TotalityCore
@testable import TotalityWeather

@Suite struct ForecastTests {
    @Test func roughLocationIsTwoDecimalPlaces() {
        let rough = Coordinate(latitude: 40.233_84, longitude: -111.658_53).rough
        #expect(rough == Coordinate(latitude: 40.23, longitude: -111.66))
    }

    @Test func onlyUSPointsCountForTheWeatherService() {
        #expect(provo.coordinate.isInUnitedStates)
        #expect(!lisbon.coordinate.isInUnitedStates)
        #expect(Coordinate(latitude: 21.3, longitude: -157.8).isInUnitedStates, "Honolulu")
    }

    @Test func unitsFollowTheRegion() {
        #expect(WeatherUnits(locale: Locale(identifier: "en_US")) == WeatherUnits(temperature: .fahrenheit, speed: .mph))
        #expect(WeatherUnits(locale: Locale(identifier: "en_GB")) == WeatherUnits(temperature: .celsius, speed: .mph))
        #expect(WeatherUnits(locale: Locale(identifier: "pt_PT")) == WeatherUnits(temperature: .celsius, speed: .kmh))
    }

    @Test func unitsConvert() {
        let us = WeatherUnits(temperature: .fahrenheit, speed: .mph)
        #expect(us.temp(5) == "41°")
        #expect(us.wind(13, from: 135) == "8 mph SE")
        #expect(us.snow(3) == "about 1 inch")
        let metric = WeatherUnits(temperature: .celsius, speed: .kmh)
        #expect(metric.temp(-0.3) == "0°", "never -0")
        #expect(metric.wind(13, from: 350) == "13 km/h N")
        #expect(metric.snow(0.2) == "a little snow")
    }

    @Test func unitsAreKeptOnTheDevice() throws {
        let defaults = try #require(UserDefaults(suiteName: "weather.test.\(UUID())"))
        WeatherUnits(temperature: .celsius, speed: .mph).store(in: defaults)
        #expect(WeatherUnits.stored(in: defaults, locale: Locale(identifier: "en_US")) == WeatherUnits(temperature: .celsius, speed: .mph))
    }

    @Test func wmoCodesBecomeConditions() {
        #expect(WeatherCondition(wmo: 0) == .clear)
        #expect(WeatherCondition(wmo: 2) == .partlyCloudy)
        #expect(WeatherCondition(wmo: 73) == .snow)
        #expect(WeatherCondition(wmo: 95) == .thunderstorm)
        #expect(WeatherCondition(wmo: 999) == .cloudy)
        #expect(WeatherCondition.snow.isSnow && WeatherCondition.rain.isWet && !WeatherCondition.fog.isWet)
    }

    @Test func nextHourSaysWhenSnowStarts() {
        let us = WeatherUnits(temperature: .fahrenheit, speed: .mph)
        let line = NextHour.summary(of: sampleForecast(), at: friday, units: us)
        #expect(line.headline == "Snow likely after 7 pm")
        #expect(line.detail == "About 1 inch overnight. Dry until then.")
        #expect(line.isSnow)
    }

    @Test func nextHourSaysWhenItIsDry() {
        let dry = sampleForecast(snowFrom: 40)
        #expect(NextHour.summary(of: dry, at: friday, units: WeatherUnits(locale: Locale(identifier: "en_US"))).headline == "No rain or snow for the next 12 hours")
    }

    @Test func nextHourUsesTheQuarterHours() {
        var forecast = sampleForecast(snowFrom: 40)
        forecast.minutes = (0..<8).map { Forecast.Minutes(start: friday.addingTimeInterval(Double($0) * 900), precipitation: $0 >= 2 ? 0.3 : 0) }
        let line = NextHour.summary(of: forecast, at: friday, units: WeatherUnits(locale: Locale(identifier: "en_US")))
        #expect(line.headline == "Rain starting around 3:00 pm")
    }

    @Test func nextHourSaysWhenRainStops() {
        var forecast = sampleForecast(snowFrom: 40)
        forecast.now.condition = .rain
        forecast.now.precipitation = 1
        forecast.minutes = (0..<8).map { Forecast.Minutes(start: friday.addingTimeInterval(Double($0) * 900), precipitation: $0 < 3 ? 0.4 : 0) }
        let line = NextHour.summary(of: forecast, at: friday, units: WeatherUnits(locale: Locale(identifier: "en_US")))
        #expect(line.headline == "Rain stopping around 3:15 pm")
    }

    @Test func daysAndHoursAreInThePlacesOwnTime() throws {
        let forecast = sampleForecast()
        let today = try #require(forecast.today(at: friday))
        #expect(forecast.calendar.component(.hour, from: today.date) == 0)
        #expect(forecast.hours(on: today).allSatisfy { forecast.calendar.isDate($0.time, inSameDayAs: friday) })
        #expect(forecast.hours(from: friday).count == 24)
        #expect(WeatherClock.day(today.date, in: denver, today: friday) == "Today")
        #expect(WeatherClock.time(try #require(today.sunset), in: denver) == "5:04 pm")
    }
}

@Suite struct SourceTests {
    static let openMeteo = """
    {"timezone":"America/Denver","utc_offset_seconds":-25200,
     "current":{"time":1795901400,"temperature_2m":5.2,"apparent_temperature":2.1,"relative_humidity_2m":52,"weather_code":2,
                "wind_speed_10m":13.0,"wind_direction_10m":135,"uv_index":2.1,"is_day":1,"precipitation":0.0},
     "minutely_15":{"time":[1795901400,1795902300],"precipitation":[0.0,null]},
     "hourly":{"time":[1795899600,1795903200],"temperature_2m":[5.0,4.5],"weather_code":[2,73],"precipitation_probability":[10,60],
               "precipitation":[0.0,0.6],"snowfall":[0.0,0.5],"is_day":[1,1]},
     "daily":{"time":[1795849200],"weather_code":[73],"temperature_2m_max":[8.3],"temperature_2m_min":[-2.2],
              "precipitation_probability_max":[60],"sunrise":[1795875000],"sunset":[1795910640],"uv_index_max":[2.4]}}
    """

    @Test func openMeteoIsReadInMetric() throws {
        let forecast = try OpenMeteoSource.parse(Data(Self.openMeteo.utf8), fetchedAt: friday)
        #expect(forecast.timeZone == "America/Denver")
        #expect(forecast.now.temperature == 5.2 && forecast.now.condition == .partlyCloudy)
        #expect(forecast.minutes.count == 1, "a missing quarter is left out")
        #expect(forecast.hours.map(\.condition) == [.partlyCloudy, .snow])
        #expect(forecast.days.first?.high == 8.3 && forecast.days.first?.chance == 60)
        #expect(forecast.source == "Open-Meteo")
    }

    @Test func aBrokenAnswerIsRefused() {
        #expect(throws: WeatherError.badAnswer) { try OpenMeteoSource.parse(Data("{}".utf8), fetchedAt: friday) }
    }

    @Test func requestsCarryOnlyTheRoughLocation() async throws {
        let http = FakeHTTP()
        http.answer("api.open-meteo.com", with: Self.openMeteo)
        _ = try await OpenMeteoSource(http: http).forecast(at: Coordinate(latitude: 40.233_84, longitude: -111.658_53))
        let url = try #require(http.requests.first?.absoluteString)
        #expect(url.contains("latitude=40.23") && url.contains("longitude=-111.66"))
        #expect(!url.contains("40.233"))
    }

    @Test func alertsAreRead() throws {
        let json = """
        {"features":[
          {"id":"a","properties":{"id":"urn:1","event":"Winter Weather Advisory","headline":"Advisory until 5 AM","severity":"Moderate",
           "ends":"2026-11-29T05:00:00-07:00","description":"Snow 1 to 3 inches.","instruction":"Slow down.","senderName":"NWS Salt Lake City UT","status":"Actual"}},
          {"id":"b","properties":{"id":"urn:2","event":"Winter Storm Warning","headline":"Warning","severity":"Severe","status":"Actual"}},
          {"id":"c","properties":{"id":"urn:3","event":"Test Message","severity":"Minor","status":"Test"}}]}
        """
        let alerts = try NWSAlerts.parse(Data(json.utf8))
        #expect(alerts.map(\.event) == ["Winter Storm Warning", "Winter Weather Advisory"])
        #expect(alerts[1].details == "Snow 1 to 3 inches.\n\nSlow down.")
        #expect(alerts[1].ends != nil)
    }

    @Test func aPointOutsideTheUSIsNeverSentForAlerts() async throws {
        let http = FakeHTTP()
        #expect(try await NWSAlerts(http: http).alerts(at: lisbon.coordinate).isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test func airQualityAndPollenAreRead() throws {
        let json = #"{"current":{"us_aqi":42,"pm2_5":8.1,"grass_pollen":61.0,"birch_pollen":3.0,"olive_pollen":null}}"#
        let air = try AirQualitySource.parse(Data(json.utf8))
        #expect(air.usIndex == 42 && air.category == "Good")
        #expect(air.topPollen?.name == "Grass" && air.topPollen?.level == "High")
    }

    @Test func citySearchGivesPlaces() throws {
        let json = #"{"results":[{"name":"Provo","latitude":40.23,"longitude":-111.66,"country":"United States","admin1":"Utah","timezone":"America/Denver"}]}"#
        let places = try OpenMeteoPlaces.parse(Data(json.utf8))
        #expect(places.first?.name == "Provo" && places.first?.region == "Utah, United States")
        #expect(try OpenMeteoPlaces.parse(Data("{}".utf8)).isEmpty)
    }

    @Test func extrasThatFailLeaveTheForecast() async throws {
        let http = FakeHTTP()
        http.answer("api.open-meteo.com", with: Self.openMeteo)
        let service = WeatherService(source: OpenMeteoSource(http: http), air: AirQualitySource(http: http), alerts: NWSAlerts(http: http))
        let forecast = try await service.forecast(at: provo.coordinate)
        #expect(forecast.air == nil && forecast.alerts.isEmpty)
        #expect(service.recipients == ["Open-Meteo", "the National Weather Service (US only)"])
    }
}

@Suite struct PlacesTests {
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func placesKeepTheirOrder() {
        var places = WeatherPlaces()
        places.add(provo, at: t0)
        places.add(lisbon, at: t0)
        #expect(places.places.map(\.name) == ["Provo", "Lisbon"])
        places.reorder([lisbon.id, provo.id], at: t0.addingTimeInterval(1))
        #expect(places.places.map(\.name) == ["Lisbon", "Provo"])
    }

    @Test func theSameSpotIsntAddedTwice() {
        var places = WeatherPlaces()
        places.add(provo, at: t0)
        let again = WeatherPlace(name: "Provo, UT", region: "", coordinate: Coordinate(latitude: 40.2341, longitude: -111.6579))
        #expect(places.add(again, at: t0).id == provo.id)
        #expect(places.places.count == 1)
    }

    @Test func twoDevicesComeTogether() {
        var phone = WeatherPlaces(), pad = WeatherPlaces()
        phone.add(provo, at: t0)
        pad = phone
        pad.add(lisbon, at: t0.addingTimeInterval(5))
        phone.remove(provo.id, at: t0.addingTimeInterval(10))
        let one = WeatherPlaces.merged(phone, pad), other = WeatherPlaces.merged(pad, phone)
        #expect(one == other, "the same whichever way round")
        #expect(WeatherPlaces.merged(one, one) == one, "and again on its own result")
        #expect(one.places.map(\.name) == ["Lisbon"], "the removal and the addition both survive")
    }

    @Test func aTieGoesTheSameWay() {
        var a = WeatherPlaces(), b = WeatherPlaces()
        a.add(provo, at: t0)
        b.add(provo, at: t0)
        b.remove(provo.id, at: t0.addingTimeInterval(1))
        a.reorder([provo.id], at: t0.addingTimeInterval(1))
        #expect(WeatherPlaces.merged(a, b) == WeatherPlaces.merged(b, a))
        #expect(WeatherPlaces.merged(a, b).places.isEmpty, "a removal wins a tie")
    }
}

@Suite struct VaultTests {
    @Test func placesAreSealed() async throws {
        let store = MemoryBlobStore()
        let book = WeatherPlaceBook(store: store, rootKey: try ContentRootKey.generate())
        var places = WeatherPlaces()
        places.add(provo, at: friday)
        try await book.add(places)
        #expect(await book.load().places == [provo])
        for (name, data) in store.all {
            #expect(name.hasSuffix(WeatherPlaceBook.suffix))
            #expect(!name.contains("Provo"))
            #expect(data.range(of: Data("Provo".utf8)) == nil, "the name is inside the seal")
            #expect(data.range(of: Data("40.23".utf8)) == nil, "and so is where it is")
        }
    }

    @Test func theCacheIsSealedAndForgetsRemovedPlaces() async throws {
        let store = MemoryBlobStore()
        let cache = ForecastCache(store: store, rootKey: try ContentRootKey.generate())
        try await cache.write(CachedForecast(name: "Provo", forecast: sampleForecast()), for: provo.id.uuidString)
        try await cache.write(CachedForecast(name: "Lisbon", forecast: sampleForecast()), for: lisbon.id.uuidString)
        #expect(await cache.read(provo.id.uuidString)?.name == "Provo")
        #expect(store.all.values.allSatisfy { $0.range(of: Data("Provo".utf8)) == nil })
        await cache.keepOnly([provo.id.uuidString])
        #expect(await cache.read(lisbon.id.uuidString) == nil)
        #expect(store.all.count == 1)
    }

    @Test func aClosedBookTakesNothing() async throws {
        let book = WeatherPlaceBook(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        await book.close()
        await #expect(throws: WeatherError.closed) { try await book.add(WeatherPlaces()) }
    }

    @Test func theCalendarGetsTheDayFromTheCache() async throws {
        let key = try ContentRootKey.generate()
        let store = MemoryBlobStore()
        let book = WeatherPlaceBook(store: store, rootKey: key), cache = ForecastCache(store: MemoryBlobStore(), rootKey: key)
        var places = WeatherPlaces()
        places.add(provo, at: friday)
        try await book.add(places)
        try await cache.write(CachedForecast(name: "Provo", forecast: sampleForecast()), for: provo.id.uuidString)
        let module = WeatherModule(book: book, cache: cache, units: { WeatherUnits(temperature: .fahrenheit, speed: .mph) })
        let registry = try ModuleRegistry(handlers: [module])
        var calendar = Calendar.current
        calendar.timeZone = .current
        let saturday = sampleForecast().days[1].date.addingTimeInterval(12 * 3600)
        let day = try #require(await registry.forecast(on: saturday))
        #expect(day.place == "Provo" && day.high == 45 && day.low == 27)
        #expect(day.short == "45° / 27°")
        #expect(await registry.forecast(on: friday.addingTimeInterval(30 * 86_400)) == nil, "too far ahead")
        #expect(try await module.search("pro").map(\.title) == ["Provo"])
    }
}

@MainActor
@Suite struct ModelTests {
    func model(
        location: FakeLocation? = FakeLocation(access: .denied), source: FakeSource = FakeSource(forecast: sampleForecast()),
        notices: FakeNotices? = nil, store: MemoryBlobStore = MemoryBlobStore(), key: ContentRootKey? = nil, now: Date = friday
    ) throws -> WeatherModel {
        let key = try key ?? ContentRootKey.generate()
        return WeatherModel(
            book: WeatherPlaceBook(store: store, rootKey: key), cache: ForecastCache(store: MemoryBlobStore(), rootKey: key),
            service: WeatherService(source: source, air: nil, alerts: nil), searcher: FakeSearcher(results: [provo]),
            location: location, notices: notices, defaults: UserDefaults(suiteName: "weather.test.\(UUID())")!, now: { now }
        )
    }

    @Test func emptyUntilAPlaceIsAdded() async throws {
        let model = try model()
        await model.load()
        #expect(model.isEmpty)
        #expect(model.glance == ModuleGlance(lines: ["Add a place to see its weather"], isQuiet: true))
        #expect(model.shouldAskForLocation == false, "location is off, so nothing is asked")
    }

    @Test func addingAPlaceFetchesIt() async throws {
        let source = FakeSource(forecast: sampleForecast())
        let model = try model(source: source)
        await model.load()
        #expect(await model.add(provo))
        #expect(model.shown.map(\.name) == ["Provo"])
        #expect(model.forecast(for: model.shown[0]) != nil)
        #expect(source.asked == [provo.coordinate.rough])
        model.units = WeatherUnits(temperature: .fahrenheit, speed: .mph)
        #expect(model.glance?.lines == ["Provo · 41° Partly cloudy", "H 46°  L 28°", "Snow likely after 7 pm"])
    }

    @Test func aFreshForecastIsntFetchedAgain() async throws {
        let source = FakeSource(forecast: sampleForecast())
        let model = try model(source: source)
        await model.load()
        await model.add(provo)
        await model.refresher.refresh()
        #expect(source.asked.count == 1, "fifteen minutes haven't passed")
        await model.pull()
        #expect(source.asked.count == 2, "a pull always fetches")
    }

    @Test func whereYouAreComesFirstAndRounded() async throws {
        let source = FakeSource(forecast: sampleForecast())
        let location = FakeLocation(access: .notAsked, spot: Coordinate(latitude: 40.251_23, longitude: -111.649_87))
        let model = try model(location: location, source: source)
        await model.load()
        #expect(model.shouldAskForLocation)
        await model.add(lisbon)
        await model.useMyLocation()
        #expect(!model.shouldAskForLocation)
        #expect(model.shown.map(\.name) == ["Provo", "Lisbon"])
        #expect(model.shown.first?.isHere == true)
        #expect(source.asked.contains(Coordinate(latitude: 40.25, longitude: -111.65)))
        model.stopUsingLocation()
        #expect(model.shown.map(\.name) == ["Lisbon"])
    }

    @Test func theLocationIsNeverAskedForInTheBackground() async throws {
        let location = FakeLocation(access: .notAsked, spot: provo.coordinate)
        let model = try model(location: location)
        await model.load()
        await model.add(lisbon)
        await model.refresher.refresh(.background)
        #expect(location.askedToRead == 0)
    }

    @Test func offlineSaysHowOldTheForecastIs() async throws {
        let source = FakeSource(forecast: sampleForecast())
        let model = try model(source: source)
        await model.load()
        await model.add(provo)
        source.failure = .offline
        await model.pull()
        #expect(model.problemLine?.hasPrefix("You're offline. This forecast is from") == true)
        #expect(model.forecast(for: model.shown[0]) != nil, "the last forecast still shows")
        source.failure = .failed
        await model.pull()
        #expect(model.problemLine == "Open-Meteo didn't answer. Try again in a minute.")
    }

    @Test func severeAlertsRingOnce() async throws {
        var forecast = sampleForecast()
        forecast.alerts = [
            WeatherAlert(id: "urn:1", event: "Winter Storm Warning", headline: "Heavy snow tonight", severity: .severe, ends: nil, details: "", issuer: "NWS"),
            WeatherAlert(id: "urn:2", event: "Wind Advisory", headline: "Gusty", severity: .moderate, ends: nil, details: "", issuer: "NWS"),
        ]
        let notices = FakeNotices()
        let model = try model(source: FakeSource(forecast: forecast), notices: notices)
        await model.load()
        await model.add(provo)
        #expect(notices.titles.isEmpty, "alerts are off until the person turns them on")
        await model.setAlerts(true)
        await model.pull()
        await model.pull()
        #expect(notices.titles == ["Winter Storm Warning for Provo"])
    }

    @Test func thePrivacyLineIsLiterallyTrue() async throws {
        let model = try model()
        await model.load()
        #expect(model.privacyLine == "Your places are end-to-end encrypted. To get a forecast, a rough location is sent to Open-Meteo.")
    }

    @Test func removingAndMovingPlaces() async throws {
        let model = try model()
        await model.load()
        await model.add(provo)
        await model.add(lisbon)
        await model.move(fromOffsets: [1], toOffset: 0)
        #expect(model.places.map(\.name) == ["Lisbon", "Provo"])
        await model.remove(lisbon.id)
        #expect(model.places.map(\.name) == ["Provo"])
    }

    @Test func fallbackSourceHandlesFailureAndPreservesOffline() async throws {
        let primary = FakeSource(forecast: sampleForecast())
        let fallback = FakeSource(forecast: sampleForecast())
        let combined = FallbackForecastSource(primary: primary, fallback: fallback)

        primary.failure = .failed
        let recovered = try await combined.forecast(at: provo.coordinate)
        #expect(recovered.source == fallback.name)
        #expect(fallback.asked.count == 1)

        primary.failure = .offline
        await #expect(throws: WeatherError.offline) {
            _ = try await combined.forecast(at: provo.coordinate)
        }
        #expect(fallback.asked.count == 1)
    }
}
