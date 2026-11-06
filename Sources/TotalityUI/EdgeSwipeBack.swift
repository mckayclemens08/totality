import SwiftUI

extension View {
    /// Swiping in from the left edge runs `action`, the way a pushed page goes back on iPhone. It's for a
    /// module's first page, where there's nothing pushed for the system's own swipe to go back to. Pages
    /// pushed on top cover this one, so they keep the system's swipe. Nil, or a Mac, adds nothing.
    public func edgeSwipeBack(_ action: (() -> Void)?) -> some View {
        modifier(EdgeSwipeBack(action: action))
    }
}

private struct EdgeSwipeBack: ViewModifier {
    /// How far in from the edge a swipe has to start, matching the system's own.
    private static let edge = Space.s5
    /// How far it has to travel to count, or how fast it has to be thrown.
    private static let distance = Space.s8 * 2.5
    private static let throwSpeed = Space.s8 * 10

    let action: (() -> Void)?

    func body(content: Content) -> some View {
        #if os(iOS)
        if let action {
            // The page doesn't follow the finger: home isn't drawn underneath, so it would uncover a blank.
            content
                .overlay(alignment: .leading) {
                    // A thin strip on the edge, so a swipe there never reaches rows or their swipe actions.
                    Color.clear
                        .frame(width: Self.edge)
                        .contentShape(Rectangle())
                        .gesture(swipe(then: action))
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }

    private func swipe(then action: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: Space.s2, coordinateSpace: .global)
            .onEnded { value in
                let across = value.translation.width
                let thrown = value.predictedEndTranslation.width - across > Self.throwSpeed / 4
                guard across > abs(value.translation.height), across > Self.distance || (across > Self.edge && thrown) else {
                    return
                }
                action()
            }
    }
}
