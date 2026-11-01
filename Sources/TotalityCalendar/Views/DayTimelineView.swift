import SwiftUI
import TotalityUI

/// Day and Week: an hour timeline with one column for each day shown.
struct DayTimelineView: View {
    private static let hourHeight = Space.s8
    private static let gutter = Space.s7
    private static let hours = 0..<24
    /// The timeline opens on the morning, unless today is showing.
    private static let morning = 8

    let model: CalendarModel
    let onOpen: (CalendarEntry) -> Void
    let onNew: (CalendarDay, Int) -> Void

    private var days: [CalendarDay] {
        model.visibleDays
    }

    private var openingHour: Int {
        guard days.contains(model.today) else { return Self.morning }
        return max(model.display.component(.hour, from: model.currentDate) - 1, 0)
    }

    var body: some View {
        VStack(spacing: Space.s2) {
            if days.count > 1 { headings }
            allDayRow
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        ForEach(days, id: \.self) { day in
                            DayColumn(
                                day: day, model: model, hourHeight: Self.hourHeight, hours: Self.hours,
                                onOpen: onOpen, onNew: { onNew(day, $0) }
                            )
                        }
                    }
                    .padding(.trailing, Space.s2)
                    .padding(.bottom, Space.s4)
                }
                .onAppear { proxy.scrollTo(openingHour, anchor: .top) }
            }
        }
    }

    private var headings: some View {
        let theme = Theme.current
        return HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 0)
            ForEach(days, id: \.self) { day in
                let isToday = day == model.today
                VStack(spacing: Space.s1) {
                    Text(model.written(day, .dateTime.weekday(.abbreviated)))
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                    Text("\(day.day)")
                        .font(Typeface.headline)
                        .foregroundStyle(isToday ? theme.accent.color : theme.textPrimary.color)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.written(day, .dateTime.weekday(.wide).month(.wide).day()))
                .tappable {
                    model.select(day)
                    model.mode = .day
                }
            }
        }
        .padding(.trailing, Space.s2)
    }

    @ViewBuilder private var allDayRow: some View {
        let columns = days.map { day in model.entries(on: day).filter(\.isAllDay) }
        if columns.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: Self.gutter, height: 0)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, entries in
                    VStack(spacing: Space.s1) {
                        ForEach(entries) { entry in
                            AllDayChip(entry: entry).tappable { onOpen(entry) }
                        }
                    }
                    .padding(.horizontal, Space.s1)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.trailing, Space.s2)
        }
    }

    private var hourLabels: some View {
        let theme = Theme.current
        return VStack(spacing: 0) {
            ForEach(Self.hours, id: \.self) { hour in
                Text(hour == 0 ? "" : hourName(hour))
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: Self.gutter, height: Self.hourHeight, alignment: .top)
                    .accessibilityHidden(true)
                    .id(hour)
            }
        }
    }

    private func hourName(_ hour: Int) -> String {
        let day = model.selectedDay.start(in: model.display)
        guard let date = model.display.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return "" }
        var style = Date.FormatStyle.dateTime.hour()
        style.timeZone = model.display.timeZone
        return date.formatted(style)
    }
}

private struct DayColumn: View {
    let day: CalendarDay
    let model: CalendarModel
    let hourHeight: CGFloat
    let hours: Range<Int>
    let onOpen: (CalendarEntry) -> Void
    let onNew: (Int) -> Void

    private func position(_ minute: Int) -> CGFloat {
        CGFloat(minute) / 60 * hourHeight
    }

    var body: some View {
        let theme = Theme.current
        let next = model.nextEntry?.id
        let blocks = TimelineLayout.blocks(for: model.entries(on: day), on: day, in: model.display)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(hours, id: \.self) { hour in
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(theme.surfaceSunken.color)
                                .frame(height: Space.hairline)
                            Spacer(minLength: 0)
                        }
                        .frame(height: hourHeight)
                        .accessibilityLabel("New event on \(model.written(day, .dateTime.weekday(.wide).month(.wide).day())) at \(hour):00")
                        .tappable { onNew(hour) }
                    }
                }
                ForEach(blocks) { block in
                    let width = geometry.size.width / CGFloat(block.columns)
                    TimelineTile(entry: block.entry, isNext: block.entry.id == next)
                    .tappable { onOpen(block.entry) }
                    .padding(Space.s1 / 2)
                    .frame(width: width, height: position(block.endMinute - block.startMinute))
                    .offset(x: width * CGFloat(block.column), y: position(block.startMinute))
                }
                if day == model.today {
                    SwiftUI.TimelineView(.everyMinute) { context in
                        Rectangle()
                            .fill(theme.accent.color)
                            .frame(height: Space.hairline * 2)
                            .offset(y: position(TimelineLayout.minute(of: context.date, on: day, in: model.display)))
                            .accessibilityHidden(true)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: hourHeight * CGFloat(hours.count))
        .frame(maxWidth: .infinity)
    }
}

private struct TimelineTile: View {
    let entry: CalendarEntry
    let isNext: Bool

    private var isOwn: Bool {
        if case .own = entry.source { true } else { false }
    }

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.title)
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(isNext ? theme.accent.color : isOwn ? theme.textPrimary.color : theme.textSecondary.color)
            if !entry.location.isEmpty {
                Text(entry.location)
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(.horizontal, Space.s2)
        .padding(.vertical, Space.s1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .eventSurface(isOwn: isOwn, in: RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isNext ? "Next event" : "")
    }
}

private struct AllDayChip: View {
    let entry: CalendarEntry

    private var isOwn: Bool {
        if case .own = entry.source { true } else { false }
    }

    var body: some View {
        let theme = Theme.current
        Text(entry.title)
            .font(Typeface.caption)
            .foregroundStyle(isOwn ? theme.textPrimary.color : theme.textSecondary.color)
            .lineLimit(1)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .eventSurface(isOwn: isOwn, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}
