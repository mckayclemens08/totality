import SwiftUI
import TotalityUI

struct MessagesStateAction {
    let label: String
    let run: () -> Void
}

/// A full-page message, with the one thing that can be done about it.
struct MessagesStateView: View {
    let systemImage: String
    let title: String
    let detail: String
    var busy = false
    var action: MessagesStateAction?

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            if busy {
                ProgressView().padding(.top, Space.s2)
            }
            if let action {
                Button(action.label, action: action.run)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
                    .padding(.top, Space.s3)
            }
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A short line across the top: offline, or what just went wrong.
struct Banner: View {
    let text: String

    var body: some View {
        let theme = Theme.current
        Text(text)
            .font(Typeface.caption)
            .foregroundStyle(theme.textPrimary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s3)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
            .transition(.opacity)
    }
}

/// The person's first letter, standing in for a photo until profiles reach Messages.
struct Initial: View {
    let name: String

    var body: some View {
        let theme = Theme.current
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(Typeface.headline)
            .foregroundStyle(theme.textSecondary.color)
            .frame(width: Space.s7, height: Space.s7)
            .neumorphic(.raised, in: Circle())
            .accessibilityHidden(true)
    }
}

enum MessagesTime {
    /// A time today, the weekday this week, and the date before that.
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            return days == 1 ? "Yesterday" : date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
