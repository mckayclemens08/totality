import CoreGraphics
import Foundation

/// Geometry for the home screen, kept free of SwiftUI so it can be tested. One bubble sits in the
/// centre with the rest in a ring around it, all the same size. The size comes from the space
/// available, so the flower always fits and neighbours never touch.
public struct FlowerLayout: Sendable, Equatable {
    public let diameter: CGFloat
    public let ringRadius: CGFloat
    public let ringCount: Int

    public init(ringCount: Int, in size: CGSize, margin: CGFloat = Space.s4, gap: CGFloat = Space.s3) {
        self.ringCount = ringCount
        // The ring must clear the centre bubble, and a crowded ring must also clear its own neighbours.
        let neighbourSpread = ringCount > 1 ? 1 / (2 * sin(.pi / CGFloat(ringCount))) : 1
        let spread = max(1, neighbourSpread)
        let available = max(0, min(size.width, size.height) - margin * 2)
        diameter = max(0, (available - 2 * spread * gap) / (2 * spread + 1))
        ringRadius = spread * (diameter + gap)
    }

    /// Where bubble `index` sits relative to the centre. Index 0 is the centre, and the ring starts
    /// at the top and runs clockwise.
    public func position(at index: Int) -> CGPoint {
        guard index > 0, ringCount > 0 else { return .zero }
        let angle = 2 * .pi * CGFloat(index - 1) / CGFloat(ringCount) - .pi / 2
        return CGPoint(x: ringRadius * cos(angle), y: ringRadius * sin(angle))
    }
}
