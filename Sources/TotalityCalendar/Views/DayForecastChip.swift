import SwiftUI
import TotalityCore
import TotalityUI

/// The selected day's weather beside its events, from Weather through the registry (issue 203). The
/// Calendar never imports Weather; it only reads `DayForecast`.
struct DayForecastChip: View {
    let forecast: DayForecast

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s2) {
            Image(systemName: forecast.systemImage)
                .foregroundStyle(theme.accent.color)
            Text(forecast.place)
                .foregroundStyle(theme.textSecondary.color)
            Text(forecast.short)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
        .font(Typeface.caption)
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s1 + 2)
        .neumorphic(.subtle, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.s4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(forecast.spoken)
    }
}
