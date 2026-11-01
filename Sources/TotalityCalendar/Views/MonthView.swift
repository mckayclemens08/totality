import SwiftUI
import TotalityUI

struct MonthView: View {
    let model: CalendarModel
    let onOpen: (CalendarEntry) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    private var weekdays: [String] {
        let symbols = model.display.veryShortStandaloneWeekdaySymbols
        let first = model.display.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: Space.s4) {
            ScrollView { grid }
            ScrollView { selectedDay }
                .frame(width: Space.s8 * 5)
        }
        .padding(.horizontal, Space.s4)
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                grid
                selectedDay
            }
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s4)
        }
        #endif
    }

    private var grid: some View {
        let theme = Theme.current
        return LazyVGrid(columns: columns, spacing: Space.s1) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityHidden(true)
            }
            ForEach(Array(model.month.monthGrid(in: model.display).enumerated()), id: \.offset) { _, day in
                if let day {
                    DayCell(day: day, model: model)
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
        }
    }

    private var selectedDay: some View {
        let theme = Theme.current
        let entries = model.entries(on: model.selectedDay)
        let next = model.nextEntry?.id
        return VStack(alignment: .leading, spacing: Space.s3) {
            Text(model.heading(for: model.selectedDay))
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
            if entries.isEmpty {
                Text("Nothing on this day.")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
            }
            ForEach(entries) { entry in
                EventTile(entry: entry, isNext: entry.id == next)
                    .tappable { onOpen(entry) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DayCell: View {
    /// Enough to show a day is busy. The list below has the rest.
    private static let mostMarks = 3

    let day: CalendarDay
    let model: CalendarModel

    var body: some View {
        let theme = Theme.current
        let isToday = day == model.today
        let isSelected = day == model.selectedDay
        let entries = model.entries(on: day)
        VStack(spacing: Space.s1) {
            Text("\(day.day)")
                .font(isToday ? Typeface.headline : Typeface.body)
                .foregroundStyle(isToday ? theme.accentOn.color : theme.textPrimary.color)
                .frame(width: Space.s6, height: Space.s6)
                .background {
                    if isToday {
                        Circle().fill(theme.accent.color)
                    } else if isSelected {
                        Color.clear.neumorphic(.pressed, in: Circle())
                    }
                }
            marks(entries)
        }
        .frame(maxWidth: .infinity, minHeight: Space.s7, alignment: .top)
        .accessibilityElement(children: .ignore)
        .tappable { model.choose(day) }
        .accessibilityLabel(model.written(day, .dateTime.month(.wide).day().year()))
        .accessibilityValue(entries.isEmpty ? "" : "Has events")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Titles where there's room for them, and quiet dots where there isn't.
    @ViewBuilder private func marks(_ entries: [CalendarEntry]) -> some View {
        let theme = Theme.current
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries.prefix(Self.mostMarks)) { entry in
                Text(entry.title)
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: Space.s7, alignment: .top)
        .padding(.horizontal, Space.s1)
        #else
        HStack(spacing: Space.s1 / 2) {
            ForEach(entries.prefix(Self.mostMarks)) { _ in
                Circle()
                    .fill(theme.textSecondary.color)
                    .frame(width: Space.s1, height: Space.s1)
            }
        }
        .frame(height: Space.s1)
        #endif
    }
}
