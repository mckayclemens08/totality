import SwiftUI
import TotalityUI

/// A small raised circle that fills with the accent and a check when the task is done.
struct TickMark: View {
    let isDone: Bool
    var diameter: CGFloat = Space.s5

    var body: some View {
        let theme = Theme.current
        Image(systemName: "checkmark")
            .font(Typeface.micro.weight(.bold))
            .foregroundStyle(theme.accentOn.color)
            .opacity(isDone ? 1 : 0)
            .scaleEffect(isDone ? 1 : 0.4)
            .frame(width: diameter, height: diameter)
            .background {
                if isDone { Circle().fill(theme.accent.color) }
            }
            .neumorphic(.subtle, in: Circle())
            .animation(Motion.quick, value: isDone)
            .accessibilityHidden(true)
    }
}

/// The tick box as a button, with room around it for a finger.
struct TickBox: View {
    let isDone: Bool
    let title: String
    var diameter: CGFloat = Space.s5
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TickMark(isDone: isDone, diameter: diameter)
                .frame(width: Space.s6, height: Space.s6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDone ? "Mark \(title) as not done" : "Complete \(title)")
    }
}
