import SwiftUI
import TotalityUI

/// One event on a list, in the same raised look as a text box (owner, 2026-11-11). Every event is raised
/// and readable, wherever it comes from.
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
        if case .device(let event) = entry.source, !event.calendarTitle.isEmpty { parts.append(event.calendarTitle) }
        if !entry.location.isEmpty { parts.append(entry.location) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let theme = Theme.current
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Text(time)
                .font(Typeface.caption)
                .foregroundStyle(isNext ? theme.accent.color : theme.textSecondary.color)
                .frame(minWidth: Space.s8, alignment: .leading)
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
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
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
