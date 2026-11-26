import SwiftUI
import TotalityUI

/// The four parts' switch, as the mockup draws it: one raised bar, the chosen part filled with the accent.
struct ClockTabs: View {
    @Binding var selection: ClockModel.Tab

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s1) {
            ForEach(ClockModel.Tab.allCases, id: \.self) { tab in
                let isOn = tab == selection
                Button {
                    withMotion(Motion.snappy) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(Typeface.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isOn ? theme.accentOn.color : theme.textSecondary.color)
                        .frame(maxWidth: .infinity, minHeight: Space.s6 + Space.s1 + Space.s1 / 2)
                        .background {
                            if isOn { RoundedRectangle(cornerRadius: Radius.sm + Space.s1, style: .continuous).fill(theme.accent.color) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPress())
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(Space.s1 + Space.s1 / 4)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

/// A big raised button with words, like Start, Pause or Lap.
struct ClockButton: View {
    let title: String
    var systemImage: String?
    var isProminent = false
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            HStack(spacing: Space.s2) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title)
            }
            .font(Typeface.headline)
            .foregroundStyle(isProminent ? theme.accentOn.color : theme.textPrimary.color)
            .frame(maxWidth: .infinity, minHeight: Space.s7 + Space.s1 / 2)
            .background {
                if isProminent { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(theme.accent.color) }
            }
            .modifier(RaisedIfPlain(isPlain: !isProminent))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(SoftPress())
    }
}

private struct RaisedIfPlain: ViewModifier {
    let isPlain: Bool

    func body(content: Content) -> some View {
        if isPlain {
            content.neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        } else {
            content
        }
    }
}

/// A quiet line with a small icon, like the mockup's notes under the alarms.
struct ClockNote: View {
    let systemImage: String
    let text: String

    var body: some View {
        let theme = Theme.current
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typeface.caption)
        .foregroundStyle(theme.textSecondary.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An empty part's words and its one button.
struct ClockEmpty: View {
    let title: String
    let detail: String
    let button: String?
    var action: () -> Void = {}

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(title)
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                ClockButton(title: button, systemImage: "plus", isProminent: true, action: action)
                    .padding(.top, Space.s2)
            }
        }
        .itemCard()
    }
}

/// The days an alarm repeats on, as round buttons in the week's own order.
struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    let calendar: Calendar

    var body: some View {
        let theme = Theme.current
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: Space.s1 + Space.s1 / 2) {
            ForEach(order, id: \.self) { day in
                let isOn = days.contains(day)
                Button {
                    if isOn { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[day - 1])
                        .font(Typeface.callout.weight(.semibold))
                        .foregroundStyle(isOn ? theme.accentOn.color : theme.textSecondary.color)
                        .frame(width: Space.s6 + Space.s1 + Space.s1 / 2, height: Space.s6 + Space.s1 + Space.s1 / 2)
                        .background { if isOn { Circle().fill(theme.accent.color) } }
                        .modifier(RaisedCircleIf(isPlain: !isOn))
                        .contentShape(Circle())
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RaisedCircleIf: ViewModifier {
    let isPlain: Bool

    func body(content: Content) -> some View {
        if isPlain { content.neumorphic(.subtle, in: Circle()) } else { content }
    }
}

extension View {
    /// A section's small heading.
    func clockHeading() -> some View {
        font(Typeface.caption.weight(.semibold))
            .foregroundStyle(Theme.current.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.s1)
    }
}

/// An hour and minute as a date today, for a time picker.
func timeDate(hour: Int, minute: Int, calendar: Calendar) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
}

/// "7:30" and "am" apart, as the mockup sets them.
func timeParts(hour: Int, minute: Int, calendar: Calendar) -> (time: String, suffix: String) {
    let date = timeDate(hour: hour, minute: minute, calendar: calendar)
    let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    let text = date.formatted(style)
    for marker in [calendar.amSymbol, calendar.pmSymbol] where text.hasSuffix(marker) {
        return (String(text.dropLast(marker.count)).trimmingCharacters(in: .whitespaces), marker.lowercased())
    }
    return (text, "")
}

/// A city's time now, split like `timeParts`.
func cityTime(_ city: WorldCity, at now: Date, calendar: Calendar) -> (time: String, suffix: String) {
    var there = calendar
    there.timeZone = city.timeZone ?? calendar.timeZone
    return timeParts(hour: there.component(.hour, from: now), minute: there.component(.minute, from: now), calendar: calendar)
}
