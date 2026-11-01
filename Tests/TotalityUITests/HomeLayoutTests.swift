import CoreGraphics
import Foundation
import Testing
import TotalityCore
@testable import TotalityUI

@Suite("Home layout")
struct HomeLayoutTests {
    private static let modules = ModuleID.allCases
    private static let metrics = BentoMetrics(width: 361)

    /// A layout with no big square and exactly these tiles, in this order.
    private func layout(_ tiles: [(ModuleID, TileSize)]) -> HomeLayout {
        var layout = HomeLayout(modules: tiles.map(\.0))
        layout.setSize(tiles[0].1, of: tiles[0].0)
        for (index, tile) in tiles.enumerated() {
            layout.setSize(tile.1, of: tile.0)
            if index > 0 { layout.move(tile.0, to: layout.tiles[index].id) }
        }
        if let hero = layout.hero { layout.setSize(layout.size(of: hero) ?? .small, of: hero) }
        return layout
    }

    private func place(_ layout: HomeLayout, _ id: ModuleID) throws -> TilePlacement {
        try #require(layout.placements.first { $0.id == id })
    }

    private func overlaps(_ layout: HomeLayout) -> Bool {
        let frames = layout.placements.map(Self.metrics.frame(of:))
        return frames.indices.contains { first in
            frames.indices.contains { first < $0 && frames[first].intersects(frames[$0]) }
        }
    }

    @Test("A new install has every module once, with the big square left as a choice")
    func starting() {
        let layout = HomeLayout(modules: Self.modules)
        #expect(layout.tiles.map(\.id).sorted { $0.rawValue < $1.rawValue } == Self.modules.sorted { $0.rawValue < $1.rawValue })
        #expect(layout.placements.count == Self.modules.count)
        #expect(layout.hero == nil)
        #expect(layout.tiles.first == HomeTile(id: .reader, size: .large))
        #expect(!overlaps(layout))
    }

    @Test("A small tile is square, medium is 2:1, large is taller, and the big square is square")
    func shapes() throws {
        var layout = self.layout([(.reader, .small), (.mail, .medium), (.player, .large), (.money, .small)])
        layout.makeHero(.money)
        let metrics = Self.metrics
        let hero = metrics.frame(of: try place(layout, .money))
        let small = metrics.frame(of: try place(layout, .reader))
        let medium = metrics.frame(of: try place(layout, .mail))
        let large = metrics.frame(of: try place(layout, .player))
        #expect(small.width == small.height)
        #expect(hero.width == hero.height)
        #expect(hero.width == 361)
        #expect(medium.width == 361)
        #expect(medium.height == small.height)
        #expect(large.width == 361)
        #expect(large.height > medium.height)
        #expect(large.height < hero.height)
    }

    @Test("Tiles never overlap and all stay inside the width, whatever the sizes")
    func neverOverlaps() throws {
        let sizes = TileSize.allCases
        for seed in 0..<300 {
            var layout = HomeLayout(modules: Self.modules)
            for (index, module) in Self.modules.enumerated() {
                layout.setSize(sizes[(seed * (index + 3) + seed / 7) % sizes.count], of: module)
            }
            if seed % 3 == 0 { layout.makeHero(Self.modules[seed % Self.modules.count]) }
            #expect(layout.placements.count == Self.modules.count)
            #expect(!overlaps(layout))
            for placement in layout.placements {
                #expect(Self.metrics.frame(of: placement).maxX <= 361)
                #expect(placement.column + placement.columns <= 2)
            }
        }
    }

    @Test("A later small tile fills the gap beside an earlier one")
    func fillsGaps() throws {
        let layout = layout([(.reader, .small), (.calendar, .medium), (.mail, .small)])
        let mail = try place(layout, .mail)
        #expect(mail.column == 1)
        #expect(mail.row == 0)
        #expect(try place(layout, .calendar).row == 2)
    }

    @Test("Tiles keep their order when nothing needs filling")
    func keepsOrder() {
        let layout = layout([(.reader, .medium), (.calendar, .small), (.mail, .small), (.player, .large)])
        #expect(layout.placements.map(\.id) == [.reader, .calendar, .mail, .player])
        #expect(layout.placements.map(\.row) == [0, 2, 2, 4])
        #expect(layout.placements.map(\.column) == [0, 0, 1, 0])
    }

    @Test("The big square sits at the top, wherever its tile is in the order")
    func heroOnTop() throws {
        var layout = layout([(.reader, .small), (.calendar, .small), (.mail, .medium)])
        layout.makeHero(.mail)
        let hero = try place(layout, .mail)
        #expect(hero.row == 0)
        #expect(hero.column == 0)
        #expect(hero.columns == 2)
        #expect(hero.rows == 4)
        #expect(layout.placements.filter { $0.id == .mail }.count == 1)
        #expect(try place(layout, .reader).row == 4)
    }

    @Test("A new big square releases the old one, at the size and place it had")
    func oneHero() throws {
        var layout = layout([(.reader, .large), (.calendar, .small), (.mail, .small)])
        layout.makeHero(.reader)
        layout.makeHero(.calendar)
        #expect(layout.hero == .calendar)
        #expect(layout.size(of: .reader) == .large)
        #expect(try place(layout, .reader).rows == 3)
        #expect(layout.placements.filter { $0.rows == 4 }.map(\.id) == [.calendar])
    }

    @Test("Choosing a size for the big square makes it an ordinary tile")
    func sizeReleasesHero() {
        var layout = layout([(.reader, .small), (.calendar, .small)])
        layout.makeHero(.calendar)
        layout.setSize(.medium, of: .calendar)
        #expect(layout.hero == nil)
        #expect(layout.size(of: .calendar) == .medium)
        layout.setSize(.large, of: .reader)
        #expect(layout.size(of: .reader) == .large)
    }

    @Test("A module that isn't on the page can't become the big square")
    func heroMustExist() {
        var layout = layout([(.reader, .small)])
        layout.makeHero(.money)
        #expect(layout.hero == nil)
    }

    @Test("Moving takes the target's place, in both directions")
    func moves() {
        var layout = layout([(.reader, .small), (.calendar, .small), (.mail, .small), (.player, .small)])
        layout.move(.player, to: .calendar)
        #expect(layout.tiles.map(\.id) == [.reader, .player, .calendar, .mail])
        layout.move(.reader, to: .calendar)
        #expect(layout.tiles.map(\.id) == [.player, .calendar, .reader, .mail])
        layout.move(.reader, to: .reader)
        #expect(layout.tiles.map(\.id) == [.player, .calendar, .reader, .mail])
    }

    @Test("A wide tile rises above two small tiles, whichever of them it's dragged onto", arguments: [ModuleID.messages, .mail])
    func wideTileRises(onto target: ModuleID) throws {
        var layout = HomeLayout(modules: [.messages, .mail, .ai])
        #expect(try place(layout, .ai).row > place(layout, .messages).row)

        layout.move(.ai, to: target)

        #expect(try place(layout, .ai).row == 0)
        #expect(try place(layout, .messages).row == place(layout, .mail).row)
        #expect(try place(layout, .messages).row > 0)
        #expect(!overlaps(layout))
    }

    @Test("It rises under a tile that isn't moving, too")
    func wideTileRisesUnderATile() throws {
        var layout = HomeLayout(modules: [.reader, .messages, .mail, .ai])
        layout.move(.ai, to: .mail)
        #expect(layout.tiles.map(\.id) == [.reader, .ai, .messages, .mail])
    }

    @Test("A wide tile drops below two small tiles the same way", arguments: [ModuleID.messages, .mail])
    func wideTileDrops(onto target: ModuleID) throws {
        var layout = HomeLayout(modules: [.messages, .mail, .ai])
        layout.move(.ai, to: .messages)
        let top = try place(layout, .ai)
        layout.move(.ai, to: target)
        #expect(try place(layout, .ai) != top)
        #expect(try place(layout, .ai).row > place(layout, .messages).row)
    }

    @Test("Passing tiles stops as soon as the tile has moved")
    func moveStopsWhenMoved() {
        var layout = HomeLayout(modules: [.messages, .mail, .player, .photos])
        layout.move(.photos, to: .mail)
        #expect(layout.tiles.map(\.id) == [.messages, .photos, .mail, .player])
    }

    @Test("Move earlier and later follow what's on screen")
    func steps() {
        var layout = layout([(.reader, .small), (.calendar, .small), (.mail, .small)])
        #expect(!layout.canMove(.reader, by: -1))
        #expect(!layout.canMove(.mail, by: 1))
        #expect(layout.canMove(.reader, by: 1))
        layout.move(.mail, by: -1)
        #expect(layout.tiles.map(\.id) == [.reader, .mail, .calendar])
        layout.move(.reader, by: 1)
        #expect(layout.tiles.map(\.id) == [.mail, .reader, .calendar])
    }

    @Test("Moving a tile always moves it, even past a gap it would slide back into")
    func stepsPastGaps() throws {
        // On screen: Reader and Mail side by side, the Calendar under them.
        var layout = layout([(.reader, .small), (.calendar, .medium), (.mail, .small)])
        #expect(!layout.canMove(.calendar, by: 1))
        let before = try place(layout, .calendar)
        layout.move(.calendar, by: -1)
        #expect(try place(layout, .calendar) != before)
        #expect(try place(layout, .calendar).row == 0)
        #expect(layout.placements.count == 3)
    }

    @Test("A move is one place on screen, even when the saved order differs from it")
    func stepsOnePlace() throws {
        // On screen: Reader and Mail side by side, the Calendar under them.
        var layout = layout([(.reader, .small), (.calendar, .medium), (.mail, .small)])
        layout.move(.reader, by: 1)
        #expect(try place(layout, .mail).row == 0)
        #expect(try place(layout, .mail).column == 0)
        #expect(try place(layout, .reader).row == 0)
        #expect(try place(layout, .reader).column == 1)
        #expect(try place(layout, .calendar).row == 2)
    }

    @Test("Moving steps over the big square, which has no place in the order")
    func stepsOverHero() {
        var layout = layout([(.reader, .small), (.calendar, .small), (.mail, .small)])
        layout.makeHero(.calendar)
        #expect(!layout.canMove(.calendar, by: 1))
        #expect(!layout.canMove(.calendar, by: -1))
        layout.move(.mail, by: -1)
        #expect(layout.placements.map(\.id).prefix(1) == [.calendar])
        #expect(layout.placements.dropFirst().sorted { $0.column < $1.column }.map(\.id) == [.mail, .reader])
    }

    @Test("An arrangement survives being saved")
    func roundTrip() {
        var layout = HomeLayout(modules: Self.modules)
        layout.setSize(.large, of: .money)
        layout.move(.money, to: .calendar)
        layout.makeHero(.photos)
        #expect(HomeLayout(saved: layout.saved, modules: Self.modules) == layout)
    }

    @Test("What's saved is module names and sizes, nothing else")
    func savedHoldsNoContent() throws {
        let saved = try #require(try JSONSerialization.jsonObject(with: HomeLayout(modules: Self.modules).saved) as? [String: Any])
        #expect(Set(saved.keys).subtracting(["hero"]) == ["tiles"])
    }

    @Test("Unreadable data gives the starting layout", arguments: [Data(), Data("not json".utf8), Data("{}".utf8), Data(#"{"tiles":[],"hero":null}"#.utf8)])
    func unreadable(data: Data) {
        #expect(HomeLayout(saved: data, modules: Self.modules) == HomeLayout(modules: Self.modules))
    }

    @Test("A module added by an update joins the end, and nothing is lost")
    func newModuleJoins() {
        let older = Self.modules.filter { $0 != .web }
        var layout = HomeLayout(modules: older)
        layout.setSize(.large, of: .money)
        let updated = HomeLayout(saved: layout.saved, modules: Self.modules)
        #expect(updated.tiles.last == HomeTile(id: .web, size: .small))
        #expect(updated.tiles.dropLast() == layout.tiles[...])
        #expect(updated.hero == layout.hero)
    }

    @Test("A removed or unknown module drops out, and a duplicate counts once")
    func cleansUp() {
        let json = #"{"tiles":[{"module":"mail","size":"large"},{"module":"gone","size":"small"},{"module":"mail","size":"small"},{"module":"reader","size":"huge"}],"hero":"gone"}"#
        let layout = HomeLayout(saved: Data(json.utf8), modules: [.mail, .reader, .calendar])
        #expect(layout.tiles == [HomeTile(id: .mail, size: .large), HomeTile(id: .reader, size: .small), HomeTile(id: .calendar, size: .small)])
        #expect(layout.hero == nil)
    }

    @Test("A big square whose module is gone is released")
    func heroGone() {
        var layout = HomeLayout(modules: Self.modules)
        layout.makeHero(.money)
        let fewer = Self.modules.filter { $0 != .money }
        let restored = HomeLayout(saved: layout.saved, modules: fewer)
        #expect(restored.hero == nil)
        #expect(!restored.tiles.contains { $0.id == .money })
    }

    @Test("Tiles are the default home page and Flower is the other choice")
    func styles() {
        #expect(HomeStyle.allCases == [.tiles, .flower])
        #expect(HomeStyle.allCases.map(\.name) == ["Tiles", "Flower"])
    }

    @Test("A point finds the tile under it, and a gap finds nothing")
    func findsTiles() throws {
        let layout = layout([(.reader, .small), (.calendar, .small), (.mail, .medium)])
        let placements = layout.placements
        let metrics = Self.metrics
        #expect(metrics.placement(at: CGPoint(x: 20, y: 20), among: placements)?.id == .reader)
        #expect(metrics.placement(at: CGPoint(x: 340, y: 20), among: placements)?.id == .calendar)
        let mail = metrics.frame(of: try place(layout, .mail))
        #expect(metrics.placement(at: CGPoint(x: mail.midX, y: mail.midY), among: placements)?.id == .mail)
        #expect(metrics.placement(at: CGPoint(x: 180.5, y: 20), among: placements) == nil)
        #expect(metrics.placement(at: CGPoint(x: 20, y: mail.maxY + 1), among: placements) == nil)
    }
}
