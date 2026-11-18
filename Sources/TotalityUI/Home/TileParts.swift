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
        .buttonStyle(SoftPress())
    }
}

private struct IsArrangingHome: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on Home's tiles while they're being arranged, when each has a remove button on its corner.
    public var isArrangingHome: Bool {
        get { self[IsArrangingHome.self] }
        set { self[IsArrangingHome.self] = newValue }
    }
}

/// The small icon and words at the top of a tile, like "Mail · 3 new". Tinted tiles show it in the
/// accent. While Home is arranged it moves over to clear the remove button.
public struct TileHeader: View {
    let title: String
    let systemImage: String
    let isTinted: Bool
    @Environment(\.isArrangingHome) private var isArranging

    public init(_ title: String, systemImage: String, isTinted: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isTinted = isTinted
    }

    public var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s1 + Space.s1 / 2) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
        }
        .font(Typeface.tileLabel)
        .foregroundStyle(isTinted ? theme.accent.color : theme.textSecondary.color)
        .padding(.leading, isArranging ? Space.s3 : 0)
        .motion(Motion.snappy, value: isArranging)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// A tile's content inset from its edge, filling the tile from the top.
    public func tilePadding() -> some View {
        padding(Metric.tileGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A tile drawn on the soft accent wash rather than the plain surface, like Reader while it listens.
    public func tileTint() -> some View {
        background(Theme.current.highlight.color)
    }
}

/// A tile's list: as many rows as fit. When some are left out, the rows spread to the tile's bottom
/// edge, so a large tile never ends in a gap a row didn't fit into. When all fit, they sit at the top
/// like the canvas.
public struct TileList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let row: (Item) -> Row

    public init(_ items: [Item], spacing: CGFloat = Metric.tileRowGap, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.spacing = spacing
        self.row = row
    }

    public var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(Array(stride(from: items.count, to: 0, by: -1)), id: \.self) { count in
                rows(count, spreads: count < items.count)
            }
        }
    }

    private func rows(_ count: Int, spreads: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(count).enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    if spreads { Spacer(minLength: spacing) } else { Color.clear.frame(height: spacing) }
                }
                row(item)
            }
        }
        .frame(maxHeight: spreads ? .infinity : nil, alignment: .top)
    }
}
