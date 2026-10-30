import CoreGraphics
import Testing
import TotalityCore
@testable import TotalityUI

@Suite("Bubble cloud layout")
struct BubbleLayoutTests {
    let layout = BubbleLayout()
    let phone = CGSize(width: 393, height: 760)

    @Test func firstBubbleIsTheCentre() {
        #expect(layout.position(at: 0) == .zero)
    }

    @Test("No two bubbles overlap, even with far more modules than today")
    func bubblesNeverOverlap() {
        let points = (0..<61).map(layout.position)
        for (index, a) in points.enumerated() {
            for b in points[(index + 1)...] {
                #expect(hypot(a.x - b.x, a.y - b.y) >= BubbleLayout.bubbleDiameter)
            }
        }
    }

    @Test("Each ring is one spacing out from the last")
    func ringsAreEvenlySpaced() {
        for index in 1...6 {
            let point = layout.position(at: index)
            #expect(abs(hypot(point.x, point.y) - layout.spacing) < 0.001)
        }
    }

    @Test("Bubbles shrink towards the edge and never below a tap target")
    func scaleFallsOff() {
        var previous = CGFloat.infinity
        for distance in stride(from: CGFloat(0), through: 900, by: 30) {
            let scale = layout.scale(at: CGPoint(x: distance, y: 0), in: phone)
            #expect(scale <= previous)
            #expect(scale * BubbleLayout.bubbleDiameter >= 44)
            previous = scale
        }
        #expect(layout.scale(at: .zero, in: phone) == 1)
        #expect(layout.scale(at: CGPoint(x: 900, y: 0), in: phone) == BubbleLayout.minimumScale)
    }

    @Test func zeroSizedViewDoesNotCrash() {
        #expect(layout.scale(at: .zero, in: .zero) == BubbleLayout.minimumScale)
    }

    @Test("Panning stops once the outermost bubble reaches the centre")
    func panningIsClamped() {
        let count = ModuleEntry.all.count
        let limit = hypot(layout.position(at: count - 1).x, layout.position(at: count - 1).y)
        let clamped = layout.clampedOffset(CGSize(width: 5000, height: 0), count: count)
        #expect(abs(clamped.width - limit) < 0.001)
        let small = CGSize(width: 10, height: -10)
        #expect(layout.clampedOffset(small, count: count) == small)
    }

    @Test("Every module has exactly one home entry")
    func everyModuleIsListed() {
        #expect(Set(ModuleEntry.all.map(\.id)) == Set(ModuleID.allCases))
        #expect(ModuleEntry.all.count == ModuleID.allCases.count)
    }
}
