import SwiftUI
import TotalityUI

/// One event on a list: its time, then a raised card. Every event is raised and readable, wherever it
/// comes from.
struct EventTile: View {
    let entry: CalendarEntry
    let isNext: Bool

    private var isOwn: Bool {
        if case .own = entry.source { true } else { false }
    }

    private var time: String {
        entry.isAllDay ? "All day" : entry.start.formatted(date: .omitted, time: .shortened)
    }

    private var caption: String {
        var parts: [String] = []
        // "7:00 – 7:45 AM", as on the canvas.
        if !entry.isAllDay, entry.end > entry.start {
            parts.append((entry.start..<entry.end).formatted(.interval.hour().minute()))
        }
        if case .device(let event) = entry.source, !event.calendarTitle.isEmpty { parts.append(event.calendarTitle) }
        if !entry.location.isEmpty { parts.append(entry.location) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let theme = Theme.current
        // The time sits beside the card, and the card holds the event (redesign, 2026-11-17).
        HStack(alignment: .top, spacing: Space.s3) {
            Text(time)
                .font(Typeface.caption)
                .monospacedDigit()
                .foregroundStyle(isNext ? theme.accent.color : theme.textSecondary.color)
                .frame(width: Space.s7 + Space.s1, alignment: .trailing)
                .padding(.top, Space.s4)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(entry.title)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                if !caption.isEmpty {
                    Text(caption)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                if isNext {
                    Text("Next")
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(theme.accent.color)
                        .padding(.top, Space.s1)
                }
            }
            .itemCard()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isNext ? "Next event" : "")
    }
}

extension View {
    /// For anything a swipe can cross. A Button also fires when a swipe ends on it, so swiping to the
    /// next day would open what the finger happened to pass over. A tap gesture gives way to the drag.
    func tappable(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    /// Blocks on the day timeline. None are pressed in: that look read as an old text box.
    func eventSurface<S: Shape>(isOwn: Bool, in shape: S) -> some View {
        neumorphic(.subtle, in: shape)
    }
}
