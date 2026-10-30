import CoreGraphics

/// Geometry for the home screen's bubble cloud, kept free of SwiftUI so it can be tested.
/// Bubbles sit on a honeycomb spiralling out from the centre.
public struct BubbleLayout: Sendable {
    public static let bubbleDiameter: CGFloat = 84
    /// Keeps the smallest bubble at 46pt, above the 44pt minimum tap target.
    public static let minimumScale: CGFloat = 0.55

    public let spacing: CGFloat

    public init(spacing: CGFloat = 104) {
        self.spacing = spacing
    }

    /// Where bubble `index` sits relative to the cloud's centre. Index 0 is the centre.
    public func position(at index: Int) -> CGPoint {
        guard index > 0 else { return .zero }
        var ring = 1
        var remaining = index - 1
        while remaining >= ring * 6 {
            remaining -= ring * 6
            ring += 1
        }
        let directions = [(-1, 1), (-1, 0), (0, -1), (1, -1), (1, 0), (0, 1)]
        var q = ring
        var r = 0
        for step in 0..<remaining {
            let direction = directions[step / ring]
            q += direction.0
            r += direction.1
        }
        return CGPoint(
            x: spacing * (CGFloat(q) + CGFloat(r) / 2),
            y: spacing * (3.0.squareRoot() / 2) * CGFloat(r)
        )
    }

    /// Full size in the middle of the screen, shrinking towards the edges.
    public func scale(at point: CGPoint, in size: CGSize) -> CGFloat {
        let reach = min(size.width, size.height) / 2
        guard reach > 0 else { return Self.minimumScale }
        let progress = (hypot(point.x, point.y) / reach - 0.45) / 0.75
        let clamped = min(max(progress, 0), 1)
        let eased = clamped * clamped * (3 - 2 * clamped)
        return 1 - eased * (1 - Self.minimumScale)
    }

    /// Limits panning so the outermost bubble can reach the centre and no further.
    public func clampedOffset(_ offset: CGSize, count: Int) -> CGSize {
        let limit = (0..<count).map { index -> CGFloat in
            let point = position(at: index)
            return hypot(point.x, point.y)
        }.max() ?? 0
        let distance = hypot(offset.width, offset.height)
        guard distance > limit, distance > 0 else { return offset }
        return CGSize(width: offset.width * limit / distance, height: offset.height * limit / distance)
    }
}
