import SwiftUI
import TotalityUI

/// The Calendar's home tile at each size (redesign, 2026-11-17). Small is today's date and the next
/// event. Medium lists what's coming, the next one on the soft accent. Large has this week across the
/// top, today on the accent, and what's coming under it, as much as fits. A day opens that day, and an
/// event opens itself.
public struct CalendarHomeTile: View {
    private static let mostRows = 8

    private let model: CalendarModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    /// `onOpen` brings the Calendar up after a day or an event has been asked for.
    public init(model: CalendarModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    private func open(_ target: CalendarModel.Target) {
        model.request(target)
        onOpen()
    }

    /// What's still to come, from today on: today's all-day events, then timed ones not yet over.
    private var upcoming: [CalendarEntry] {
        let current = model.currentDate
        return model.schedule.flatMap { day, entries in
            entries.filter { day == model.today ? ($0.isAllDay || $0.end > current) : true }
        }
    }

    public var body: some View {
        Group {
            switch size {
            case .small: small
            case .medium: medium
            case .large: large
            }
        }
        .tilePadding()
    }

    // MARK: Small: the date and what's next

    private var small: some View {
        let theme = Theme.current
        let next = model.nextEntry
        return VStack(alignment: .leading, spacing: 0) {
            TileHeader("Calendar", systemImage: "calendar")
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text("\(model.today.day)")
                    .font(Typeface.display)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                Text(model.written(model.today, .dateTime.weekday(.abbreviated)))
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary.color)
            }
            .padding(.top, Space.s1)
            .tileLink(model.heading(for: model.today)) { open(.day(model.today)) }
            Spacer(minLength: Space.s2)
            if let next {
                VStack(alignment: .leading, spacing: 0) {
                    Text(when(next))
                        .font(Typeface.micro.weight(.semibold))
                        .foregroundStyle(theme.accent.color)
                    Text(next.title)
                        .font(Typeface.caption.weight(.bold))
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(2)
                }
                .tileLink("Next: \(next.title)") { open(.entry(next)) }
            } else {
                Text("Nothing coming up")
                    .font(Typeface.tileDetail)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
    }

    // MARK: Medium: what's coming

    private var medium: some View {
        VStack(alignment: .leading, spacing: Metric.tileItemGap) {
            TileHeader("Calendar · \(model.written(model.today, .dateTime.weekday(.wide).day()))", systemImage: "calendar")
            fitting(3)
        }
    }

    // MARK: Large: this week, then what's coming

    private var large: some View {
        VStack(alignment: .leading, spacing: Metric.tileItemGap) {
            TileHeader("Calendar · \(model.written(model.today, .dateTime.month(.wide)))", systemImage: "calendar")
            week
            fitting(Self.mostRows)
        }
    }

    /// As many of what's coming as fit, up to `limit`, so the tile has no empty bottom.
    @ViewBuilder private func fitting(_ limit: Int) -> some View {
        let shown = Array(upcoming.prefix(limit))
        if shown.isEmpty {
            events([])
        } else {
            let next = model.nextEntry
            TileList(shown, spacing: Space.s2 + Space.s1 / 4) { entry in
                card(entry, isNext: entry.id == next?.id)
            }
        }
    }

    private var week: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s1 / 2) {
            ForEach(Array(model.thisWeek.enumerated()), id: \.offset) { index, day in
                let isToday = day == model.today
                VStack(spacing: 0) {
                    Text(model.weekdayLetters[index])
                        .font(Typeface.micro)
                        .foregroundStyle(isToday ? theme.accentOn.color : theme.textSecondary.color)
                    Text("\(day.day)")
                        .font(Typeface.callout.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? theme.accentOn.color : theme.textPrimary.color)
                }
                .padding(.vertical, Space.s1 + Space.s1 / 2)
                .frame(maxWidth: .infinity)
                .background {
                    if isToday {
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(theme.accent.color)
                    }
                }
                .tileLink(model.heading(for: day)) { open(.day(day)) }
            }
        }
    }

    @ViewBuilder private func events(_ entries: [CalendarEntry]) -> some View {
        if entries.isEmpty {
            Text("Nothing coming up")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textSecondary.color)
                .padding(.top, Space.s1)
        } else {
            let next = model.nextEntry
            VStack(spacing: Space.s2) {
                ForEach(entries) { entry in
                    card(entry, isNext: entry.id == next?.id)
                }
            }
        }
    }

    private func card(_ entry: CalendarEntry, isNext: Bool) -> some View {
        EventCard(entry: entry, detail: detail(entry, isNext: isNext),
                  time: entry.isAllDay ? "All day" : entry.start.formatted(date: .omitted, time: .shortened),
                  isNext: isNext)
            .tileLink(entry.title) { open(.entry(entry)) }
    }

    /// Under the title: where it is, and for the next one, how soon.
    private func detail(_ entry: CalendarEntry, isNext: Bool) -> String {
        let place = entry.location.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = place.isEmpty ? [] : [place]
        if isNext, !entry.isAllDay {
            let current = model.currentDate
            if entry.start <= current {
                parts.append("now")
            } else if entry.start.timeIntervalSince(current) < 60 * 60 * 12 {
                parts.append("in " + Self.soon(entry.start.timeIntervalSince(current)))
            }
        }
        if CalendarDay(entry.start, in: model.display) != model.today {
            parts.insert(model.written(CalendarDay(entry.start, in: model.display), .dateTime.weekday(.abbreviated)), at: 0)
        }
        return parts.joined(separator: " · ")
    }

    /// "25 min" or "3 h".
    static func soon(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }

    private func when(_ entry: CalendarEntry) -> String {
        if entry.start <= model.currentDate { return "Now" }
        let time = entry.start.formatted(date: .omitted, time: .shortened)
        if CalendarDay(entry.start, in: model.display) == model.today { return time }
        return "\(model.written(CalendarDay(entry.start, in: model.display), .dateTime.weekday(.abbreviated))) \(time)"
    }
}

/// One event as a card: the next one on the soft accent with an accent dot, the rest raised.
private struct EventCard: View {
    let entry: CalendarEntry
    let detail: String
    let time: String
    let isNext: Bool

    var body: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.sm + Space.s1 / 2, style: .continuous)
        HStack(spacing: Metric.tileItemGap) {
            Circle()
                .fill(isNext ? theme.accent.color : theme.textTertiary.color)
                .frame(width: Space.s2, height: Space.s2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title)
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.textPrimary.color)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .lineLimit(1)
            Spacer(minLength: Space.s1)
            Text(time)
                .font(Typeface.tileDetail)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
        }
        .padding(.horizontal, Metric.tileItemGap)
        .padding(.vertical, Space.s2 + Space.s1 / 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A flat wash of the page colour, as on the canvas, or the accent wash for what's next.
        .background(isNext ? theme.highlight.color : theme.bg.color, in: shape)
    }
}
