import SwiftUI

/// Pieces the big home tiles share, so Mail and Messages draw faces, counts and buttons alike without
/// importing each other (issue 127).

/// A person on a tile: their face, a count of what's unread from them, and their first name under it.
public struct TileFace: View {
    let photo: Data?
    let name: String
    let count: Int
    let diameter: CGFloat

    public init(photo: Data?, name: String, count: Int = 0, diameter: CGFloat = Space.s7) {
        self.photo = photo
        self.name = name
        self.count = count
        self.diameter = diameter
    }

    /// A first name, or the whole of a name that's one word, such as an address.
    public static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s1) {
            PersonFace(photo: photo, name: name, diameter: diameter)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        TileCount(count)
                            .offset(x: Space.s1, y: -Space.s1)
                    }
                }
            Text(Self.shortName(name))
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
        }
        .frame(width: diameter + Space.s4)
    }
}

/// A number on the one accent colour, as on a face or a chip.
public struct TileCount: View {
    let count: Int

    public init(_ count: Int) {
        self.count = count
    }

    public var body: some View {
        let theme = Theme.current
        Text(count > 99 ? "99+" : "\(count)")
            .font(Typeface.micro)
            .monospacedDigit()
            .foregroundStyle(theme.accentOn.color)
            .padding(.horizontal, Space.s1 + Space.s1 / 2)
            .frame(minWidth: Space.s5 - Space.s1, minHeight: Space.s5 - Space.s1)
            .background(theme.accent.color, in: Capsule())
            .accessibilityHidden(true)
    }
}

/// One account's name and its unread count, on a soft chip.
public struct TileChip: View {
    let name: String
    let count: Int

    public init(_ name: String, count: Int) {
        self.name = name
        self.count = count
    }

    public var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s1) {
            Text(name)
                .lineLimit(1)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(count > 0 ? theme.textPrimary.color : theme.textTertiary.color)
        }
        .font(Typeface.micro)
        .foregroundStyle(theme.textSecondary.color)
        .padding(.horizontal, Space.s2)
        .padding(.vertical, Space.s1)
        .neumorphic(.subtle, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count) unread")
    }
}

/// A small soft button on a tile. Put `tileControl()` on it so it hears its press.
public struct TileButton: View {
    let title: String
    let systemImage: String
    let isProminent: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String, isProminent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isProminent = isProminent
        self.action = action
    }

    public var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Typeface.callout)
                .foregroundStyle(isProminent ? theme.accent.color : theme.textSecondary.color)
                .lineLimit(1)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .neumorphic(.subtle, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
