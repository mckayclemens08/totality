import CoreGraphics
import Testing
@testable import TotalityUI

@Suite struct BrandMarkTests {
    @Test("The mark's two slabs fill their square and stay inside it")
    func glyphFitsItsSquare() {
        let rect = CGRect(x: 0, y: 0, width: 50, height: 50)
        let bounds = BrandGlyph().path(in: rect).boundingRect
        #expect(!bounds.isEmpty)
        #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds))
        #expect(bounds.width > 40 && bounds.height > 40)
    }

    @Test("The launch screen never holds anyone longer than about a second and a half")
    func launchLimit() {
        #expect(LaunchView.limit <= .milliseconds(1500))
        #expect(LaunchView.limit > .zero)
    }
}
