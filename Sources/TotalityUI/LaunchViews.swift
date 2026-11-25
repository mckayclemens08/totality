import SwiftUI

/// Totality's mark, as on the app icon: two soft slabs split on the diagonal, on a raised tile.
public struct BrandMark: View {
    let size: CGFloat

    public init(size: CGFloat = Metric.launchMark) {
        self.size = size
    }

    public var body: some View {
        BrandGlyph()
            .fill(Theme.current.textPrimary.color)
            .frame(width: size * 0.55, height: size * 0.55)
            .frame(width: size, height: size)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The two slabs of the app icon, drawn in a 100-point square and scaled to fit.
struct BrandGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        path.move(to: p(22, 6))
        path.addLine(to: p(66, 6))
        path.addCurve(to: p(69, 14), control1: p(70, 6), control2: p(72, 11))
        path.addLine(to: p(14, 69))
        path.addCurve(to: p(6, 66), control1: p(11, 72), control2: p(6, 70))
        path.addLine(to: p(6, 22))
        path.addCurve(to: p(22, 6), control1: p(6, 13), control2: p(13, 6))
        path.closeSubpath()
        path.move(to: p(78, 94))
        path.addLine(to: p(34, 94))
        path.addCurve(to: p(31, 86), control1: p(30, 94), control2: p(28, 89))
        path.addLine(to: p(86, 31))
        path.addCurve(to: p(94, 34), control1: p(89, 28), control2: p(94, 30))
        path.addLine(to: p(94, 78))
        path.addCurve(to: p(78, 94), control1: p(94, 87), control2: p(87, 94))
        path.closeSubpath()
        return path
    }
}

/// The short branded screen while Totality restores the session and opens each module's saved content,
/// so Home is filled in when it appears (owner, 2026-11-25). It never holds anyone longer than `limit`.
public struct LaunchView: View {
    /// The longest the launch screen stays up, even when a module is slow to open.
    public static let limit = Duration.milliseconds(1500)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    public init() {}

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s4) {
            BrandMark()
            Text("Totality")
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            HStack(spacing: Space.s2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(theme.textTertiary.color)
                        .frame(width: Metric.launchDot, height: Metric.launchDot)
                        // Under Reduce Motion the dots hold still.
                        .opacity(reduceMotion ? 0.6 : (lit ? 1 : 0.3))
                        .animation(reduceMotion ? nil : Motion.pulse.delay(Double(index) * 0.15), value: lit)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.color.ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Totality is opening")
        .onAppear { lit = true }
    }
}
