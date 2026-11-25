import SwiftUI
import TotalityUI

extension View {
    /// Single tap opens the post, double tap likes it (never unlikes) with a heart pop over the card.
    /// VoiceOver gets the same two things as actions: the default opens, "Like" likes.
    func likesOnDoubleTap(onOpen: @escaping () -> Void, onLike: @escaping () -> Void) -> some View {
        modifier(DoubleTapLike(onOpen: onOpen, onLike: onLike))
    }
}

private struct DoubleTapLike: ViewModifier {
    let onOpen: () -> Void
    let onLike: () -> Void
    @State private var popping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // The double tap is tried first, so a single tap opens as soon as the system knows no second tap is coming.
            .gesture(TapGesture(count: 2).onEnded { like() }.exclusively(before: TapGesture().onEnded { onOpen() }))
            .overlay { heart }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onOpen)
            .accessibilityAction(named: "Like", like)
    }

    private var heart: some View {
        Image(systemName: "heart.fill")
            .resizable().scaledToFit()
            .frame(width: Space.s8, height: Space.s8)
            .foregroundStyle(Theme.current.accent.color)
            // Reduce Motion: a plain fade in place. Otherwise the heart grows in.
            .scaleEffect(reduceMotion ? 1 : (popping ? 1.1 : 0.4))
            .opacity(popping ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func like() {
        onLike()
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : Motion.bouncy) { popping = true }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { popping = false }
        }
    }
}
