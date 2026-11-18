import SwiftUI

// The shared pieces of the 2026-11-17 redesign, which every module's screens use. Each is raised or
// accent-filled, never pressed in (issue 132), and reads only the tokens.

/// A screen's big bold title, with an optional line above it such as today's date.
public struct ScreenTitle: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s1) {
            if let subtitle {
                Text(subtitle)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Text(title)
                .font(Typeface.display)
                .foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A raised round button in a screen's header. Its title is what VoiceOver says.
public struct HeaderButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    public init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.body.weight(.semibold))
                .foregroundStyle(Theme.current.textSecondary.color)
                .frame(width: Metric.headerButton, height: Metric.headerButton)
                .neumorphic(.subtle, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(title)
    }
}

/// A word button in a header, as tall as `HeaderButton`: raised, or accent-filled for the main action.
public struct HeaderPill: View {
    let title: String
    let systemImage: String?
    let isProminent: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, isProminent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isProminent = isProminent
        self.action = action
    }

    public var body: some View {
        let theme = Theme.current
        Button(action: action) {
            HStack(spacing: Space.s2) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(isProminent ? theme.accentOn.color : theme.accent.color)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(Typeface.callout.weight(.semibold))
            .foregroundStyle(isProminent ? theme.accentOn.color : theme.textSecondary.color)
            .padding(.horizontal, Space.s4)
            .frame(height: Metric.headerButton)
            .background {
                if isProminent { Capsule().fill(theme.accent.color) }
            }
            .modifier(RaisedUnless(isFlat: isProminent, shape: Capsule()))
            .contentShape(Capsule())
        }
        .buttonStyle(SoftPress())
    }
}

/// One of a row of filters. The chosen one is filled with the accent; the rest are raised.
public struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Text(title)
                .font(Typeface.callout)
                .foregroundStyle(isSelected ? theme.accentOn.color : theme.textSecondary.color)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)
                .background {
                    if isSelected { Capsule().fill(theme.accent.color) }
                }
                .modifier(RaisedUnless(isFlat: isSelected, shape: Capsule()))
                .contentShape(Capsule())
        }
        .buttonStyle(SoftPress())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A row of filter pills that scrolls sideways when it runs out of room.
public struct FilterPills<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    public init(_ items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String) {
        self.items = items
        _selection = selection
        self.title = title
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(items, id: \.self) { item in
                    FilterPill(title(item), isSelected: item == selection) {
                        withAnimation(Motion.quick) { selection = item }
                    }
                }
            }
            // Room for the shadow pair, which a scroll view would clip.
            .padding(Space.s2)
        }
    }
}

extension View {
    /// A raised card around one item in a list: a row of mail, a task, an event.
    public func itemCard() -> some View {
        padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    /// The accent round + at the bottom right of a screen. Its title is what VoiceOver says.
    public func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        overlay(alignment: .bottomTrailing) {
            AddButton(title, action: action)
                .padding(Space.s4)
        }
    }
}

/// The accent round + that starts something new. Usually placed with `.addButton(_:action:)`.
public struct AddButton: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Image(systemName: "plus")
                .font(Typeface.title.weight(.semibold))
                .foregroundStyle(theme.accentOn.color)
                .frame(width: Metric.addButton, height: Metric.addButton)
                .background(Circle().fill(theme.accent.color))
                .shadow(color: theme.shadowDark.color, radius: Elevation.raised.offset * 2, x: Elevation.raised.offset, y: Elevation.raised.offset)
                .contentShape(Circle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(title)
    }
}

/// How far along something is, as a ring: a `highlight` track with an accent arc from the top.
/// Whatever is passed as content sits in the middle.
public struct ProgressRing<Content: View>: View {
    let progress: Double
    let diameter: CGFloat
    let content: Content

    public init(progress: Double, diameter: CGFloat, @ViewBuilder content: () -> Content) {
        self.progress = progress
        self.diameter = diameter
        self.content = content()
    }

    public var body: some View {
        let theme = Theme.current
        let fraction = progress.isFinite ? min(max(progress, 0), 1) : 0
        ZStack {
            Circle()
                .stroke(theme.highlight.color, lineWidth: Metric.ringStroke)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(theme.accent.color, style: StrokeStyle(lineWidth: Metric.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            content
        }
        .padding(Metric.ringStroke / 2)
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

extension ProgressRing where Content == EmptyView {
    public init(progress: Double, diameter: CGFloat) {
        self.init(progress: progress, diameter: diameter) { EmptyView() }
    }
}

/// A press makes a control a little smaller and fainter. Nothing sinks in (issue 132).
public struct SoftPress: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? TilePress.scale : 1)
            .opacity(configuration.isPressed ? TilePress.opacity : 1)
            .animation(Motion.instant, value: configuration.isPressed)
    }
}

/// Raised, unless the control already has a fill of its own.
private struct RaisedUnless<S: Shape>: ViewModifier {
    let isFlat: Bool
    let shape: S

    func body(content: Content) -> some View {
        if isFlat {
            content
        } else {
            content.neumorphic(.subtle, in: shape)
        }
    }
}
