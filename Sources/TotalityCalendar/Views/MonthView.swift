import SwiftUI
import TotalityUI

struct MonthView: View {
    let model: CalendarModel
    @Environment(\.colorScheme) private var scheme

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    private var weekdays: [String] {
        let symbols = model.display.veryShortStandaloneWeekdaySymbols
        let first = model.display.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        let theme = Theme.current(scheme)
        let entries = model.entries(on: model.selectedDay)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                CalendarNotes(model: model)
                header
                LazyVGrid(columns: columns, spacing: Space.s1) {
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
                Text(model.selectedDay.start(in: model.display).formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                if entries.isEmpty {
                    Text("Nothing on this day.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                }
                ForEach(entries) { entry in
                    NavigationLink(value: entry) {
                        EntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s4)
        }
    }

    private var header: some View {
        let theme = Theme.current(scheme)
        return HStack(spacing: Space.s3) {
            Button("Previous month", systemImage: "chevron.left") { model.show(monthsFromNow: -1) }
                .labelStyle(.iconOnly)
            Text(model.month.start(in: model.display).formatted(.dateTime.month(.wide).year()))
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
                .frame(maxWidth: .infinity)
            Button("Next month", systemImage: "chevron.right") { model.show(monthsFromNow: 1) }
                .labelStyle(.iconOnly)
            Button("Today") { model.showToday() }
                .font(Typeface.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent.color)
    }
}

private struct DayCell: View {
    let day: CalendarDay
    let model: CalendarModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.current(scheme)
        let isToday = day == model.today
        let isSelected = day == model.selectedDay
        let hasEntries = !model.entries(on: day).isEmpty
        Button {
            model.selectedDay = day
        } label: {
            VStack(spacing: Space.s1) {
                Text("\(day.day)")
                    .font(isToday ? Typeface.headline : Typeface.body)
                    .foregroundStyle(isToday ? theme.accent.color : theme.textPrimary.color)
                Circle()
                    .fill(hasEntries ? theme.accent.color : Color.clear)
                    .frame(width: Space.s1, height: Space.s1)
            }
            .frame(maxWidth: .infinity, minHeight: Space.s7)
            .background {
                if isSelected {
                    Color.clear.neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.start(in: model.display).formatted(date: .long, time: .omitted))
        .accessibilityValue(hasEntries ? "Has events" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
