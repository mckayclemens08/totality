import SwiftUI
import TotalityCore
import TotalityUI

/// Weather's home tile at each size (issue 203, section 6, after issue 127's rule). Small is a glance:
/// where, the temperature, the sky, high and low, and the next-hour line. Medium lists the places with
/// their temperatures. Large has the next six hours, the next three days, and chips to switch place.
public struct WeatherHomeTile: View {
    private let model: WeatherModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    public init(model: WeatherModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            if let shown = model.current, let forecast = model.forecast(for: shown) {
                switch size {
                case .small: small(shown, forecast)
                case .medium: medium
                case .large: large(shown, forecast)
                }
            } else {
                quiet
            }
        }
        .tilePadding()
    }

    private var quiet: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            TileHeader("Weather", systemImage: "cloud.sun")
            Spacer(minLength: 0)
            Text(model.isEmpty ? "Add a place to see its weather" : "Getting the forecast")
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
        }
    }

    private func open(_ shown: WeatherModel.Shown) {
        model.selected = shown.key
        onOpen()
    }

    // MARK: Small

    private func small(_ shown: WeatherModel.Shown, _ forecast: Forecast) -> some View {
        let theme = Theme.current
        let units = model.units
        let today = forecast.today(at: Date())
        return VStack(alignment: .leading, spacing: Space.s1) {
            TileHeader(shown.name, systemImage: shown.isHere ? "location.fill" : "cloud.sun")
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(units.temp(forecast.now.temperature))
                    .font(Typeface.display)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                Image(systemName: forecast.now.condition.systemImage(isDaylight: forecast.now.isDaylight))
                    .font(Typeface.headline)
                    .foregroundStyle(theme.accent.color)
            }
            Text(forecast.now.condition.name)
                .font(Typeface.tileLabel)
                .foregroundStyle(theme.textPrimary.color)
            if let today {
                Text("H \(units.temp(today.high))  L \(units.temp(today.low))")
                    .font(Typeface.tileDetail)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            Text(NextHour.summary(of: forecast, at: Date(), units: units).headline)
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.accent.color)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Medium

    private var medium: some View {
        let theme = Theme.current
        let units = model.units
        let shown = model.shown.filter { model.forecast(for: $0) != nil }
        return VStack(alignment: .leading, spacing: Metric.tileItemGap) {
            TileHeader("Weather", systemImage: "cloud.sun")
            TileList(Array(shown.prefix(4))) { place in
                let forecast = model.forecast(for: place)!
                HStack(spacing: Space.s2) {
                    if place.isHere {
                        Image(systemName: "location.fill")
                            .font(Typeface.micro)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Text(place.name)
                        .font(Typeface.tileRow)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Spacer(minLength: Space.s2)
                    Image(systemName: forecast.now.condition.systemImage(isDaylight: forecast.now.isDaylight))
                        .foregroundStyle(forecast.now.condition.isWet ? theme.accent.color : theme.textSecondary.color)
                    Text(units.temp(forecast.now.temperature))
                        .font(Typeface.tileRow.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(place.name), \(units.temp(forecast.now.temperature)), \(forecast.now.condition.name)")
                .tileLink(place.name) { open(place) }
            }
        }
    }

    // MARK: Large

    private func large(_ shown: WeatherModel.Shown, _ forecast: Forecast) -> some View {
        let theme = Theme.current
        let units = model.units
        let date = Date()
        let hours = forecast.hours(from: date, count: 6)
        let days = Array(forecast.days(from: date).prefix(3))
        let range = (days.map(\.low).min() ?? 0)...(days.map(\.high).max() ?? 1)
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                TileHeader(shown.name, systemImage: shown.isHere ? "location.fill" : "cloud.sun")
                Text(units.temp(forecast.now.temperature))
                    .font(Typeface.title)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
            }
            Text(NextHour.summary(of: forecast, at: date, units: units).headline)
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.accent.color)
                .lineLimit(1)
            HStack(spacing: 0) {
                ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                    HourColumn(hour: hour, label: index == 0 && hour.time <= date ? "Now" : WeatherClock.hour(hour.time, in: forecast.zone), units: units)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 0) {
                ForEach(days) { day in
                    DayRow(day: day, name: WeatherClock.day(day.date, in: forecast.zone, today: date), range: range, units: units)
                }
            }
            Spacer(minLength: 0)
            if model.shown.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s2) {
                        ForEach(model.shown) { place in
                            Text(place.name)
                                .font(Typeface.micro)
                                .foregroundStyle(place.key == shown.key ? theme.accent.color : theme.textSecondary.color)
                                .padding(.horizontal, Space.s3)
                                .padding(.vertical, Space.s1 + 2)
                                .toggleSurface(place.key == shown.key, in: Capsule())
                                .tileLink("Show \(place.name)") {
                                    withMotion(Motion.snappy) { model.selected = place.key }
                                }
                        }
                    }
                    .padding(Space.s1)
                }
            }
        }
    }
}
