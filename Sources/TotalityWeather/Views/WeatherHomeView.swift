import SwiftUI
import TotalityCore
import TotalityUI

/// Weather's screen, as on the approved canvas (artboard Main): Home and Places in the header, then the
/// place's name, the big temperature, the next-hour line, the hours, the ten days and the details. Swipe
/// sideways between places. Pull down to refresh.
public struct WeatherHomeView: View {
    @Bindable private var model: WeatherModel
    private let onClose: (() -> Void)?
    @State private var showsPlaces = false
    @State private var showsSettings = false
    @State private var showsMap = false
    @State private var openDay: DayChoice?
    @State private var openAlert: WeatherAlert?
    @Environment(\.openURL) private var openURL

    public init(model: WeatherModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    struct DayChoice: Identifiable {
        let day: Forecast.Day
        let forecast: Forecast
        let place: String
        var id: Date { day.date }
    }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.bg.color)
        .edgeSwipeBack(onClose)
        .task {
            if model.phase == .loading { await model.load() }
            model.openRequested()
            if model.shouldAskForLocation { await model.useMyLocation() }
        }
        .onChange(of: model.requestedPlace) { model.openRequested() }
        .sheet(isPresented: $showsPlaces) {
            PlacesSheet(model: model) { showsPlaces = false }
        }
        .sheet(isPresented: $showsSettings) {
            WeatherSettingsSheet(model: model) { showsSettings = false }
        }
        .sheet(isPresented: $showsMap) {
            PlacesMapSheet(model: model) { showsMap = false }
        }
        .sheet(item: $openDay) { choice in
            DaySheet(day: choice.day, forecast: choice.forecast, place: choice.place, units: model.units) { openDay = nil }
        }
        .sheet(item: $openAlert) { alert in
            AlertSheet(alert: alert) { openAlert = nil }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            if let onClose {
                HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
            }
            Spacer(minLength: 0)
            AskTotalityButton(context: AIAskContext(id: "weather.home", module: .weather, title: "Weather"))
            if model.phase == .ready {
                HeaderButton("Map", systemImage: "map") { showsMap = true }
                HeaderButton("Weather settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                HeaderPill("Places", systemImage: "list.bullet") { showsPlaces = true }
            }
        }
        .frame(minHeight: Metric.headerButton)
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { loadingCards.padding(Space.s4) }
        case .failed:
            ModuleMessageBody(
                systemImage: "lock.slash", title: "Weather can't open",
                detail: "Your places couldn't be read on this device. Your other content isn't affected."
            )
        case .ready:
            if model.isEmpty {
                ScrollView { emptyState.padding(Space.s4) }
                    .refreshable { await model.pull() }
            } else {
                pages
            }
        }
    }

    // MARK: Places, side by side

    private var pages: some View {
        TabView(selection: Binding(get: { model.current?.key ?? "" }, set: { model.selected = $0 })) {
            ForEach(model.shown) { shown in
                ScrollView {
                    page(shown)
                        .padding(.horizontal, Space.s4)
                        .padding(.bottom, Space.s6)
                }
                .refreshable { await model.pull() }
                .tag(shown.key)
            }
        }
        #if os(iOS)
        // The system's dots sit in their own tinted strip and nearly vanish on the page, so they're drawn
        // here: the page background runs to the bottom edge, and the dots reserve their own row, so the
        // last row never sits under them.
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.shown.count > 1 { pageDots }
        }
        #endif
    }

    private var pageDots: some View {
        let theme = Theme.current
        let current = model.current?.key
        return HStack(spacing: Space.s2) {
            ForEach(model.shown) { shown in
                Circle()
                    .fill(shown.key == current ? theme.accent.color : theme.textTertiary.color)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Space.s5 + Space.s2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Place \((model.shown.firstIndex { $0.key == current } ?? 0) + 1) of \(model.shown.count)")
    }

    @ViewBuilder
    private func page(_ shown: WeatherModel.Shown) -> some View {
        let theme = Theme.current
        let date = Date()
        VStack(alignment: .leading, spacing: Space.s4) {
            if let line = model.problemLine {
                Label(line, systemImage: line.hasPrefix("You're offline") ? "wifi.slash" : "exclamationmark.arrow.triangle.2.circlepath")
                    .font(Typeface.caption)
                    .foregroundStyle(line.hasPrefix("You're offline") ? theme.textSecondary.color : theme.danger.color)
            }
            if shown.isHere, model.locationAccess == .denied {
                locationDenied
            }
            VStack(alignment: .leading, spacing: 0) {
                if shown.isHere {
                    Label("Current location", systemImage: "location.fill")
                        .font(Typeface.tileLabel)
                        .foregroundStyle(theme.textSecondary.color)
                }
                Text(shown.name)
                    .font(Typeface.display)
                    .foregroundStyle(theme.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)
            }
            if let forecast = model.forecast(for: shown) {
                forecastBody(forecast, place: shown.name, date: date)
            } else {
                loadingCards
            }
        }
    }

    @ViewBuilder
    private func forecastBody(_ forecast: Forecast, place: String, date: Date) -> some View {
        let theme = Theme.current
        let units = model.units
        let today = forecast.today(at: date)
        HStack(alignment: .center, spacing: Space.s4) {
            Text(units.temp(forecast.now.temperature))
                .font(.system(size: Space.s8 + Space.s2, weight: .bold, design: .default))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
            VStack(alignment: .leading, spacing: Space.s1) {
                Image(systemName: forecast.now.condition.systemImage(isDaylight: forecast.now.isDaylight))
                    .font(Typeface.title)
                    .foregroundStyle(theme.accent.color)
                Text(forecast.now.condition.name)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                if let today {
                    Text("H \(units.temp(today.high))  L \(units.temp(today.low)) · Feels like \(units.temp(forecast.now.feelsLike))")
                        .font(Typeface.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
        }
        .accessibilityElement(children: .combine)

        NextHourCard(summary: NextHour.summary(of: forecast, at: date, units: units))

        ForEach(forecast.activeAlerts(at: date)) { alert in
            AlertCard(alert: alert) { openAlert = alert }
        }

        let quarters = forecast.minutes.filter { $0.start.addingTimeInterval(15 * 60) > date }
        if quarters.contains(where: { $0.precipitation > 0 }) {
            MinuteRainBars(minutes: Array(quarters.prefix(8)), zone: forecast.zone)
        }

        HourlyStrip(hours: forecast.hours(from: date), zone: forecast.zone, units: units, now: date)

        let days = forecast.days(from: date)
        let range = (days.map(\.low).min() ?? 0)...(days.map(\.high).max() ?? 1)
        ForecastCard("10 days") {
            ForEach(days) { day in
                Button {
                    openDay = DayChoice(day: day, forecast: forecast, place: place)
                } label: {
                    DayRow(day: day, name: WeatherClock.day(day.date, in: forecast.zone, today: date), range: range, units: units)
                }
                .buttonStyle(SoftPress())
                .accessibilityHint("Shows the day's hours")
            }
        }

        details(forecast, today: today)

        footer(forecast)
    }

    private func details(_ forecast: Forecast, today: Forecast.Day?) -> some View {
        let units = model.units
        let now = forecast.now
        let columns = Array(repeating: GridItem(.flexible(), spacing: Space.s3), count: 3)
        return LazyVGrid(columns: columns, spacing: Space.s3) {
            DetailCard("Wind", units.wind(now.windSpeed, from: now.windDirection))
            DetailCard("Humidity", "\(Int(now.humidity.rounded()))%")
            if let sunset = today?.sunset {
                DetailCard("Sunset", WeatherClock.time(sunset, in: forecast.zone))
            }
            if let uv = now.uvIndex ?? today?.uvMax {
                DetailCard("UV index", "\(Int(uv.rounded()))", detail: Self.uvWords(uv))
            }
            if let air = forecast.air, let index = air.usIndex {
                DetailCard("Air quality", "\(index)", detail: air.category)
            }
            if let pollen = forecast.air?.topPollen {
                DetailCard("Pollen", pollen.level, detail: pollen.name)
            }
        }
    }

    static func uvWords(_ index: Double) -> String {
        switch index {
        case ..<3: "Low"
        case ..<6: "Moderate"
        case ..<8: "High"
        case ..<11: "Very high"
        default: "Extreme"
        }
    }

    private func footer(_ forecast: Forecast) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            Label(model.privacyLine, systemImage: "lock")
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
            HStack(spacing: Space.s1) {
                Text(forecast.source == "Apple Weather" ? "\u{F8FF} Weather" : "Weather data by \(forecast.source)")
                Text("·")
                Button("Data sources") {
                    let url = forecast.source == OpenMeteoSource.sourceName
                        ? OpenMeteoSource().attributionURL
                        : model.service.source.attributionURL
                    openURL(url)
                }
                    .underline()
                    .buttonStyle(.plain)
                if forecast.air != nil || !forecast.alerts.isEmpty {
                    Text("·")
                    Text(forecast.alerts.isEmpty ? "Air quality: Open-Meteo" : "Alerts: National Weather Service")
                }
            }
            .font(Typeface.micro)
            .foregroundStyle(theme.textSecondary.color)
            Text("Updated \(forecast.fetchedAt.formatted(.relative(presentation: .named)))")
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty, loading and denied

    private var loadingCards: some View {
        VStack(spacing: Space.s4) {
            PlaceholderCard(height: Space.s8 + Space.s5)
            PlaceholderCard(height: Space.s7)
            PlaceholderCard(height: Space.s8 + Space.s6)
            PlaceholderCard(height: Space.s8 * 3)
        }
    }

    private var emptyState: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s4) {
            Image(systemName: "cloud.sun")
                .font(Typeface.display)
                .foregroundStyle(theme.accent.color)
                .padding(.top, Space.s7)
            Text("Add a place to see its weather")
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
                .multilineTextAlignment(.center)
            if model.locationAccess != .denied {
                TileButton("Use my location", systemImage: "location", isProminent: true) {
                    Task { await model.useMyLocation() }
                }
            }
            TileButton("Search for a city", systemImage: "magnifyingglass") { showsPlaces = true }
            Text(model.locationAccess == .denied
                 ? "Location is off for Totality. You can still add places by name."
                 : "Your location is asked for only while you use the app, rounded to about 1 km, and never saved.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            if model.locationAccess == .denied { settingsButton }
        }
        .frame(maxWidth: .infinity)
    }

    private var locationDenied: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            Text("Location is off for Totality, so this can't follow you.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
            settingsButton
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        #if os(iOS)
        TileButton("Open Settings", systemImage: "gear") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        #endif
    }
}

/// A plain message filling the screen, for when Weather can't open.
struct ModuleMessageBody: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Spacer()
            Image(systemName: systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity)
    }
}
