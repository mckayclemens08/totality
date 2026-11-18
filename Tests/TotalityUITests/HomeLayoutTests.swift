import CoreGraphics
import Foundation
import Testing
import TotalityCore
@testable import TotalityUI

@Suite("Home layout")
struct HomeLayoutTests {
    private static let modules = ModuleID.allCases
    private static let metrics = BentoMetrics(width: 361)

    /// A layout with exactly these tiles, in this order.
    private func layout(_ tiles: [(ModuleID, TileSize)]) -> HomeLayout {
        let saved = tiles.map { #"{"module":"\#($0.0.rawValue)","size":"\#($0.1.rawValue)"}"# }.joined(separator: ",")
        return HomeLayout(saved: Data(#"{"tiles":[\#(saved)]}"#.utf8), modules: tiles.map(\.0))
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

    @Test("Only a tile bigger than small gets a module's own view, and an L tile asks for the square one")
    func bigSizes() {
        var layout = HomeLayout(modules: [.reader, .calendar, .photos])
        layout.setSize(.small, of: .reader)
        layout.setSize(.medium, of: .calendar)
        layout.setSize(.large, of: .photos)
        #expect(layout.bigSize(of: .reader) == nil)
        #expect(layout.bigSize(of: .calendar) == .medium)
        #expect(layout.bigSize(of: .photos) == .square)
        #expect(layout.bigSize(of: .mail) == nil)
    }

    @Test("A new install has every module once, with the Reader across the top")
    func starting() {
        let layout = HomeLayout(modules: Self.modules)
        #expect(layout.tiles.map(\.id).sorted { $0.rawValue < $1.rawValue } == Self.modules.sorted { $0.rawValue < $1.rawValue })
        #expect(layout.placements.count == Self.modules.count)
        #expect(layout.tiles.first == HomeTile(id: .reader, size: .medium))
        #expect(!overlaps(layout))
    }

    @Test("S is one column and square, M is full width and as short as S, L is full width and square")
    func shapes() throws {
        let layout = self.layout([(.reader, .small), (.mail, .medium), (.player, .large), (.money, .small)])
        let metrics = Self.metrics
        let small = metrics.frame(of: try place(layout, .reader))
        let medium = metrics.frame(of: try place(layout, .mail))
        let large = metrics.frame(of: try place(layout, .player))
        #expect(small.width == small.height)
        #expect(small.width < 361)
        #expect(medium.width == 361)
        #expect(medium.height == small.height)
        #expect(large.width == 361)
        #expect(large.height == large.width)
    }

    @Test("Tiles never overlap and all stay inside the width, whatever the sizes")
    func neverOverlaps() throws {
        let sizes = TileSize.allCases
        for seed in 0..<300 {
            var layout = HomeLayout(modules: Self.modules)
            for (index, module) in Self.modules.enumerated() {
                layout.setSize(sizes[(seed * (index + 3) + seed / 7) % sizes.count], of: module)
            }
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
        var layout = layout([(.reader, .large), (.messages, .small), (.mail, .small), (.ai, .medium)])
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
        var layout = layout([(.messages, .small), (.mail, .small), (.player, .small), (.photos, .small)])
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

    @Test("An arrangement survives being saved")
    func roundTrip() {
        var layout = HomeLayout(modules: Self.modules)
        layout.setSize(.large, of: .money)
        layout.move(.money, to: .calendar)
        #expect(HomeLayout(saved: layout.saved, modules: Self.modules) == layout)
    }

    @Test("What's saved is module names and sizes, nothing else")
    func savedHoldsNoContent() throws {
        let saved = try #require(try JSONSerialization.jsonObject(with: HomeLayout(modules: Self.modules).saved) as? [String: Any])
        #expect(Set(saved.keys) == ["tiles"])
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
    }

    @Test("A removed or unknown module drops out, and a duplicate counts once")
    func cleansUp() {
        let json = #"{"tiles":[{"module":"mail","size":"large"},{"module":"gone","size":"small"},{"module":"mail","size":"small"},{"module":"reader","size":"huge"}],"hero":"gone"}"#
        let layout = HomeLayout(saved: Data(json.utf8), modules: [.mail, .reader, .calendar])
        #expect(layout.tiles == [HomeTile(id: .mail, size: .large), HomeTile(id: .reader, size: .small), HomeTile(id: .calendar, size: .small)])
    }

    @Test("A layout saved with a big square at the top keeps that tile first, now L")
    func migratesBigSquare() throws {
        let json = #"{"hero":"calendar","tiles":[{"module":"reader","size":"large"},{"module":"mail","size":"small"},{"module":"calendar","size":"small"},{"module":"photos","size":"medium"}]}"#
        let layout = HomeLayout(saved: Data(json.utf8), modules: [.reader, .mail, .calendar, .photos])
        #expect(layout.tiles == [
            HomeTile(id: .calendar, size: .large), HomeTile(id: .reader, size: .large),
            HomeTile(id: .mail, size: .small), HomeTile(id: .photos, size: .medium),
        ])
        let top = try place(layout, .calendar)
        #expect(top.row == 0)
        #expect(top.columns == 2)
        #expect(top.rows == 4)
    }

    @Test("Every tile from an old layout survives, at its size, and the big square is never saved again")
    func migrationKeepsEveryTile() throws {
        let json = #"{"hero":"money","tiles":[{"module":"reader","size":"large"},{"module":"calendar","size":"medium"},{"module":"money","size":"small"},{"module":"mail","size":"small"}]}"#
        let layout = HomeLayout(saved: Data(json.utf8), modules: Self.modules)
        #expect(Set(layout.tiles.map(\.id)) == Set(Self.modules))
        #expect(layout.size(of: .reader) == .large)
        #expect(layout.size(of: .calendar) == .medium)
        #expect(layout.size(of: .money) == .large)
        #expect(layout.size(of: .mail) == .small)
        let saved = try #require(try JSONSerialization.jsonObject(with: layout.saved) as? [String: Any])
        #expect(saved["hero"] == nil)
        #expect(HomeLayout(saved: layout.saved, modules: Self.modules) == layout)
    }

    @Test("An old big square whose module is gone is let go, and the rest keep their order")
    func migrationHeroGone() {
        let json = #"{"hero":"gone","tiles":[{"module":"mail","size":"small"},{"module":"reader","size":"medium"}]}"#
        let layout = HomeLayout(saved: Data(json.utf8), modules: [.mail, .reader])
        #expect(layout.tiles == [HomeTile(id: .mail, size: .small), HomeTile(id: .reader, size: .medium)])
    }

    @Test("Size letters on the switch")
    func letters() {
        #expect(TileSize.allCases.map(\.letter) == ["S", "M", "L"])
    }

    @Test("The greeting follows the time of day")
    func greeting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Denver"))
        func at(_ hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: hour)))
        }
        #expect(HomeGreeting.title(at: try at(8), calendar: calendar) == "Good morning")
        #expect(HomeGreeting.title(at: try at(14), calendar: calendar) == "Good afternoon")
        #expect(HomeGreeting.title(at: try at(21), calendar: calendar) == "Good evening")
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

    @Test("Removing a module hides its tile, and adding it back puts it where it was, at the same size")
    func removeAndAddBack() throws {
        var home = HomeLayout(modules: Self.modules)
        home.setSize(.large, of: .photos)
        home.move(.photos, to: .calendar)
        let before = try place(home, .photos)
        let saved = home.saved

        home.hidden = [.photos]
        #expect(!home.placements.contains { $0.id == .photos })
        #expect(!overlaps(home))
        // What's saved on the device doesn't change: the tile is only out of sight.
        #expect(home.saved == saved)

        home.hidden = []
        #expect(try place(home, .photos) == before)
        #expect(home.size(of: .photos) == .large)
    }

    @Test("Moving a tile steps over removed ones")
    func movingPastRemoved() throws {
        var home = layout([(.reader, .small), (.photos, .small), (.mail, .small), (.web, .small)])
        home.hidden = [.photos]
        home.move(.mail, by: -1)
        let shown = home.placements.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map(\.id)
        #expect(shown == [.mail, .reader, .web])
    }

    @Test("Every module says what stays when it's removed")
    func removalWording() {
        for module in ModuleEntry.all {
            #expect(!module.summary.isEmpty)
            let message = HomeRemoval.message(for: module)
            #expect(message.contains(module.name))
            #expect(message.contains("won't be deleted"))
        }
    }
}
