import CoreGraphics
import Foundation
import Testing
import TotalityCore
@testable import TotalityUI

@Suite("Flower layout")
struct FlowerLayoutTests {
    static let sizes = [
        CGSize(width: 320, height: 568), CGSize(width: 393, height: 760),
        CGSize(width: 430, height: 800), CGSize(width: 852, height: 393), CGSize(width: 1024, height: 1366),
    ]

    private func points(_ layout: FlowerLayout) -> [CGPoint] {
        (0...layout.ringCount).map(layout.position)
    }

    @Test func theFirstBubbleIsTheCentre() {
        #expect(FlowerLayout(ringCount: 9, in: Self.sizes[1]).position(at: 0) == .zero)
    }

    @Test("Nothing overlaps at any screen size or module count", arguments: sizes, 1...16)
    func bubblesNeverOverlap(size: CGSize, count: Int) {
        let layout = FlowerLayout(ringCount: count, in: size)
        let all = points(layout)
        for (index, a) in all.enumerated() {
            for b in all[(index + 1)...] {
                #expect(hypot(a.x - b.x, a.y - b.y) >= layout.diameter + Space.s3 - 0.001)
            }
        }
    }

    @Test("The flower fits inside the margins", arguments: sizes, 1...16)
    func flowerFits(size: CGSize, count: Int) {
        let layout = FlowerLayout(ringCount: count, in: size)
        let limit = min(size.width, size.height) / 2 - Space.s4
        for point in points(layout) {
            #expect(hypot(point.x, point.y) + layout.diameter / 2 <= limit + 0.001)
        }
    }

    @Test("Every ring bubble is the same distance out and evenly spaced")
    func ringIsEven() {
        let layout = FlowerLayout(ringCount: 9, in: Self.sizes[1])
        let ring = Array(points(layout).dropFirst())
        for point in ring {
            #expect(abs(hypot(point.x, point.y) - layout.ringRadius) < 0.001)
        }
        let gaps = ring.indices.map { index -> CGFloat in
            let next = ring[(index + 1) % ring.count]
            return hypot(ring[index].x - next.x, ring[index].y - next.y)
        }
        #expect((gaps.max() ?? 0) - (gaps.min() ?? 0) < 0.001)
    }

    @Test func theRingStartsAtTheTop() {
        let layout = FlowerLayout(ringCount: 9, in: Self.sizes[1])
        let top = layout.position(at: 1)
        #expect(abs(top.x) < 0.001 && top.y < 0)
    }

    @Test("Eleven modules stay tappable on the smallest iPhone")
    func bubblesStayTappable() {
        #expect(FlowerLayout(ringCount: 10, in: Self.sizes[0]).diameter >= 44)
    }

    @Test func oneModuleSitsAloneInTheCentre() {
        #expect(FlowerLayout(ringCount: 0, in: Self.sizes[1]).position(at: 0) == .zero)
    }

    @Test("Each module appears once, with the chosen one first and the rest in order")
    func arrangement() {
        let all = ModuleEntry.all
        let arranged = ModuleEntry.arranged(all, around: .calendar)
        #expect(arranged.first?.id == .calendar)
        #expect(arranged.count == all.count)
        #expect(Set(arranged.map(\.id)).count == all.count)
        #expect(Array(arranged.dropFirst().map(\.id)) == all.map(\.id).filter { $0 != .calendar })
    }

    @Test func anUnknownCentreKeepsTheOrder() {
        let some = Array(ModuleEntry.all.prefix(3))
        #expect(ModuleEntry.arranged(some, around: .social) == some)
    }
}
