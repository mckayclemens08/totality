import SwiftUI

/// One thing on a tile that opens by itself. The rest of the tile still opens the module.
struct TileLink {
    let name: String
    let bounds: Anchor<CGRect>
    let action: @MainActor () -> Void
}

/// The grid takes every touch itself, so a button inside a tile would never hear one. Links report
/// where they are instead, and the grid checks them before opening the module.
struct TileLinkKey: PreferenceKey {
    static var defaultValue: [TileLink] { [] }

    static func reduce(value: inout [TileLink], nextValue: () -> [TileLink]) {
        value += nextValue()
    }
}

extension View {
    /// Makes this part of a tile open `action`, or nothing at all when `action` is nil. `name` is what
    /// VoiceOver reads.
    @ViewBuilder
    public func tileLink(_ name: String, action: (@MainActor () -> Void)?) -> some View {
        if let action {
            anchorPreference(key: TileLinkKey.self, value: .bounds) {
                [TileLink(name: name, bounds: $0, action: action)]
            }
        } else {
            self
        }
    }
}

/// Something on a tile that has to take its own touches, such as a button, a reply box or a row with a
/// menu. The grid's touch area sits over the tiles, so the grid draws these above it, where the tile put
/// them, and the tile keeps an invisible copy for the space. While the home page is being arranged they
/// stay in the tile and take nothing, so holding still picks the tile up.
struct TileControl {
    let bounds: Anchor<CGRect>
    let view: AnyView
}

struct TileControlKey: PreferenceKey {
    static var defaultValue: [TileControl] { [] }

    static func reduce(value: inout [TileControl], nextValue: () -> [TileControl]) {
        value += nextValue()
    }
}

private struct LiftsTileControls: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the grid's tiles while they're not being arranged. Anywhere else, such as a preview or
    /// a render, a control sits where it is like any other view.
    var liftsTileControls: Bool {
        get { self[LiftsTileControls.self] }
        set { self[LiftsTileControls.self] = newValue }
    }
}

private struct TileControlModifier: ViewModifier {
    let control: AnyView
    @Environment(\.liftsTileControls) private var lifts

    func body(content: Content) -> some View {
        if lifts {
            content
                .hidden()
                .anchorPreference(key: TileControlKey.self, value: .bounds) { [TileControl(bounds: $0, view: control)] }
        } else {
            content
        }
    }
}

extension View {
    /// Lets this part of a tile take its own touches. It's drawn outside the tile, so it has to set its
    /// own font and colours rather than take the tile's, and keep what it shows in a model rather than
    /// in `@State`, because the copy that's drawn is made again whenever the tile changes.
    public func tileControl() -> some View {
        modifier(TileControlModifier(control: AnyView(self)))
    }
}
