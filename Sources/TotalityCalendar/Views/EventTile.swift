import SwiftUI
import TotalityUI

/// One event on a list. The person's own events are raised. Device events sit in the surface, because
/// they're only shown here.
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
                    .foregroundStyle(isOwn ? theme.textPrimary.color : theme.textSecondary.color)
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
        .padding(Space.s3)
        .eventSurface(isOwn: isOwn, in: RoundedRectangle(cornerRadius: Radius.md))
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

    func eventSurface<S: Shape>(isOwn: Bool, in shape: S) -> some View {
        neumorphic(isOwn ? .subtle : .pressed, in: shape)
    }
}
