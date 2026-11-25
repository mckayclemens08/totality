import SwiftUI
import TotalityCore
import TotalityUI

/// The pieces of a place's forecast, as on the approved canvas (artboard Main): the hourly strip, the
/// ten days with their range bars, and the small detail cards. Each is raised, never pressed in.

/// A raised card around a part of the forecast.
struct ForecastCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            if let title {
                Text(title)
                    .font(Typeface.tileLabel)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

/// One hour: the time, the sky, the temperature and the chance of rain or snow.
struct HourColumn: View {
    let hour: Forecast.Hour
    let label: String
    let units: WeatherUnits

    var body: some View {
        let theme = Theme.current
        let chance = Int(hour.chance.rounded())
        VStack(spacing: Space.s1 + 2) {
            Text(label)
                .font(Typeface.tileLabel)
                .foregroundStyle(theme.textSecondary.color)
            Image(systemName: hour.condition.systemImage(isDaylight: hour.isDaylight))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(hour.condition.isWet ? theme.accent.color : theme.textSecondary.color)
                .font(Typeface.callout)
                .frame(height: Space.s5)
            Text(units.temp(hour.temperature))
                .font(Typeface.headline)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
            Text(chance >= 10 ? "\(chance)%" : " ")
                .font(Typeface.micro)
                .monospacedDigit()
                .foregroundStyle(theme.accent.color)
        }
        .frame(minWidth: Space.s7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(units.temp(hour.temperature)), \(hour.condition.name)\(chance >= 10 ? ", \(chance)% chance of rain or snow" : "")")
    }
}

/// The next hours, side by side, scrolling sideways.
struct HourlyStrip: View {
    let hours: [Forecast.Hour]
    let zone: TimeZone
    let units: WeatherUnits
    let now: Date

    var body: some View {
        ForecastCard {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s2) {
                    ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                        HourColumn(hour: hour, label: index == 0 && hour.time <= now ? "Now" : WeatherClock.hour(hour.time, in: zone), units: units)
                    }
                }
            }
        }
    }
}

/// One day: its name, chance, low, a bar from low to high across the ten days' range, and high.
struct DayRow: View {
    let day: Forecast.Day
    let name: String
    let range: ClosedRange<Double>
    let units: WeatherUnits

    var body: some View {
        let theme = Theme.current
        let chance = Int(day.chance.rounded())
        HStack(spacing: Space.s3) {
            Text(name)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: Space.s7, alignment: .leading)
            Image(systemName: day.condition.systemImage())
                .foregroundStyle(day.condition.isWet ? theme.accent.color : theme.textSecondary.color)
                .frame(width: Space.s5)
            Text(chance >= 10 ? "\(chance)%" : "")
                .font(Typeface.micro)
                .monospacedDigit()
                .foregroundStyle(theme.accent.color)
                .frame(width: Space.s6, alignment: .leading)
            Text(units.temp(day.low))
                .font(Typeface.caption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s6, alignment: .trailing)
            RangeBar(low: day.low, high: day.high, range: range)
            Text(units.temp(day.high))
                .font(Typeface.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: Space.s6, alignment: .leading)
        }
        .frame(minHeight: Metric.headerButton)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(day.condition.name), high \(units.temp(day.high)), low \(units.temp(day.low))\(chance >= 10 ? ", \(chance)% chance of rain or snow" : "")")
    }
}

/// A flat track with the accent span from the day's low to its high.
struct RangeBar: View {
    let low: Double
    let high: Double
    let range: ClosedRange<Double>

    var body: some View {
        let theme = Theme.current
        GeometryReader { proxy in
            let span = max(range.upperBound - range.lowerBound, 1)
            let start = (low - range.lowerBound) / span
            let width = max((high - low) / span, 0.04)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.highlight.color)
                Capsule().fill(theme.accent.color)
                    .frame(width: proxy.size.width * width)
                    .offset(x: proxy.size.width * start)
            }
        }
        .frame(height: Space.s1 + 2)
        .accessibilityHidden(true)
    }
}

/// A small card with one figure, such as Wind: 8 mph SE.
struct DetailCard: View {
    let title: String
    let value: String
    let detail: String?

    init(_ title: String, _ value: String, detail: String? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
    }

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s1 / 2) {
            Text(title)
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
            Text(value)
                .font(Typeface.callout.weight(.bold))
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The next-hour line in a flat accent wash, as on the canvas.
struct NextHourCard: View {
    let summary: NextHour

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Image(systemName: summary.isSnow ? "cloud.snow" : summary.isWet ? "cloud.rain" : "sun.max")
                .font(Typeface.headline)
                .foregroundStyle(theme.accent.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(summary.headline)
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary.color)
                if let detail = summary.detail {
                    Text(detail)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(theme.highlight.color))
        .accessibilityElement(children: .combine)
    }
}

/// The rain or snow in the next two hours, a bar each quarter hour. Shown only when some is coming.
struct MinuteRainBars: View {
    let minutes: [Forecast.Minutes]
    let zone: TimeZone

    var body: some View {
        let theme = Theme.current
        let most = max(minutes.map(\.precipitation).max() ?? 0, 0.5)
        ForecastCard("Next 2 hours") {
            HStack(alignment: .bottom, spacing: Space.s1) {
                ForEach(minutes, id: \.start) { quarter in
                    VStack(spacing: Space.s1) {
                        Capsule()
                            .fill(quarter.precipitation > 0 ? theme.accent.color : theme.highlight.color)
                            .frame(height: max(Space.s1, Space.s7 * quarter.precipitation / most))
                        Text(WeatherClock.time(quarter.start, in: zone).replacingOccurrences(of: " ", with: "\n"))
                            .font(Typeface.micro)
                            .foregroundStyle(theme.textSecondary.color)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Space.s7 + Space.s6, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rain or snow is expected in the next two hours")
    }
}

/// A severe weather alert, in the danger colour, opening its details.
struct AlertCard: View {
    let alert: WeatherAlert
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.danger.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(alert.event)
                        .font(Typeface.callout.weight(.semibold))
                        .foregroundStyle(theme.danger.color)
                    Text(alert.issuer)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textTertiary.color)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(SoftPress())
        .accessibilityHint("Shows the alert")
    }
}

/// A quiet stand-in while a place's first forecast is on its way.
struct PlaceholderCard: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
            .fill(Theme.current.surface.color)
            .frame(height: height)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .accessibilityHidden(true)
    }
}
