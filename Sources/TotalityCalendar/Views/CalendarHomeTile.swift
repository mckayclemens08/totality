import SwiftUI
import TotalityUI

/// The Calendar's big home tile: this week on a medium tile, the whole month on a larger one, and on the
/// square the month with a "Next up" card under it (issue 127). A day opens that day, and a line or the
/// card opens what it's about.
public struct CalendarHomeTile: View {
    private let model: CalendarModel
    private let size: BigTileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings the Calendar up after a day or an event has been asked for.
    public init(model: CalendarModel, size: BigTileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private func open(_ target: CalendarModel.Target) {
        model.request(target)
        onOpen()
    }

    public var body: some View {
        switch size {
        case .medium: week
        case .large: month
        case .square:
            VStack(alignment: .leading, spacing: Space.s3) {
                month
                if let next = model.nextEntry {
                    NextUpCard(entry: next, model: model)
                        .tileLink("Next up: \(next.title)") { open(.entry(next)) }
                        .layoutPriority(1)
                } else {
                    lines
                        .layoutPriority(1)
                }
            }
        }
    }

    private var week: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: 0) {
                ForEach(Array(model.thisWeek.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: Space.s1) {
                        WeekdayLetter(letter: model.weekdayLetters[index])
                        TileDay(day: day, model: model)
                    }
                    .frame(maxWidth: .infinity)
                    .tileLink(model.heading(for: day)) { open(.day(day)) }
                }
            }
            lines
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var month: some View {
        let theme = Theme.current
        let days = model.today.monthGrid(in: model.display)
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        // The rows share what's left, which is how a six-week month still fits under the title's space.
        return VStack(alignment: .leading, spacing: 0) {
            Text(model.written(model.today, .dateTime.month(.wide)))
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
                .padding(.bottom, Space.s4)
            HStack(spacing: 0) {
                ForEach(Array(model.weekdayLetters.enumerated()), id: \.offset) { _, letter in
                    WeekdayLetter(letter: letter)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, Space.s1)
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        Group {
                            if let day {
                                TileDay(day: day, model: model)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tileLink(day.map(model.heading(for:)) ?? "", action: day.map { day in { open(.day(day)) } })
                    }
                }
            }
        }
    }

    /// What's next, then how much is on today.
    private var lines: some View {
        let theme = Theme.current
        let glance = model.glance
        return VStack(alignment: .leading, spacing: Space.s1) {
            ForEach(Array((glance?.lines ?? []).prefix(2).enumerated()), id: \.offset) { index, line in
                let isLead = index == 0 && glance?.isQuiet != true
                Text(line)
                    .font(isLead ? Typeface.headline : Typeface.caption)
                    .foregroundStyle(isLead ? theme.textPrimary.color : theme.textSecondary.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tileLink(line, action: model.glanceTarget(at: index).map { target in { open(target) } })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WeekdayLetter: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(Typeface.micro)
            .foregroundStyle(Theme.current.textSecondary.color)
    }
}

/// A day number, marked when it's today, with a dot when something's on.
private struct TileDay: View {
    let day: CalendarDay
    let model: CalendarModel

    var body: some View {
        let theme = Theme.current
        let isToday = day == model.today
        Text("\(day.day)")
            .font(Typeface.caption)
            .monospacedDigit()
            .foregroundStyle(isToday ? theme.accentOn.color : theme.textPrimary.color)
            .frame(width: Space.s5, height: Space.s5)
            .background {
                if isToday { Circle().fill(theme.accent.color) }
            }
            .overlay(alignment: .bottom) {
                if !isToday, !model.entries(on: day).isEmpty {
                    Circle()
                        .fill(theme.textSecondary.color)
                        .frame(width: Space.s1 / 2 + Space.s1 / 4, height: Space.s1 / 2 + Space.s1 / 4)
                }
            }
    }
}

/// The next timed event: what, when and where.
private struct NextUpCard: View {
    let entry: CalendarEntry
    let model: CalendarModel

    var body: some View {
        let theme = Theme.current
        let place = entry.location.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("Next up")
                .font(Typeface.micro)
                .foregroundStyle(theme.accent.color)
            Text(entry.title)
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            HStack(spacing: Space.s3) {
                Label(model.nextUpTime(entry), systemImage: "clock")
                    .lineLimit(1)
                if !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .lineLimit(1)
                }
            }
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}
