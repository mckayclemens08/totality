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
