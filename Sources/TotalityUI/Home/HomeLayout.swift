import CoreGraphics
import Foundation
import TotalityCore

/// A tile's size, in the grid's two columns and in rows half a small tile tall.
public enum TileSize: String, Codable, Sendable, CaseIterable {
    case small, medium, large

    public var name: String {
        rawValue.capitalized
    }

    var columns: Int {
        self == .small ? 1 : 2
    }

    var rows: Int {
        self == .large ? 3 : 2
    }
}

public struct HomeTile: Equatable, Sendable, Identifiable {
    public let id: ModuleID
    public var size: TileSize

    public init(id: ModuleID, size: TileSize) {
        self.id = id
        self.size = size
    }
}

/// Where a tile sits, counted in columns and rows.
public struct TilePlacement: Equatable, Sendable, Identifiable {
    public let id: ModuleID
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int
}

/// Which home page shows. Tiles unless the person sets another default in Settings. The button on the
/// home page switches for the moment and leaves the default alone.
public enum HomeStyle: String, CaseIterable, Sendable, Identifiable {
    case tiles, flower

    public static let defaultKey = "home.defaultStyle"

    public var id: Self { self }

    public var name: String {
        rawValue.capitalized
    }
}

/// The home page as the person arranged it, saved on this device. It holds module names and sizes,
/// never content.
public struct HomeLayout: Equatable, Sendable {
    static let columns = 2
    private static let heroRows = 4

    public private(set) var tiles: [HomeTile]
    /// The big square at the top. Its tile keeps its place and size, so it goes back to them when
    /// another module takes over.
    public private(set) var hero: ModuleID?

    /// A new install's home page. Modules that aren't listed join at the end as small tiles.
    public init(modules: [ModuleID]) {
        let starting: [HomeTile] = [
            .init(id: .reader, size: .large), .init(id: .calendar, size: .medium),
            .init(id: .messages, size: .small), .init(id: .mail, size: .small),
            .init(id: .ai, size: .medium),
            .init(id: .player, size: .small), .init(id: .photos, size: .small),
            .init(id: .money, size: .small), .init(id: .calls, size: .small),
            .init(id: .social, size: .medium), .init(id: .web, size: .medium),
        ]
        tiles = starting
        fit(to: modules)
    }

    /// A saved arrangement, or the starting one if it can't be read. Tiles for modules that no longer
    /// exist drop out and new modules join the end, so an update can't lose a tile.
    public init(saved: Data, modules: [ModuleID]) {
        self.init(modules: modules)
        guard let stored = try? JSONDecoder().decode(Stored.self, from: saved) else { return }
        var seen = Set<ModuleID>()
        let restored = stored.tiles.compactMap { tile -> HomeTile? in
            guard let id = ModuleID(rawValue: tile.module), let size = TileSize(rawValue: tile.size),
                  seen.insert(id).inserted
            else { return nil }
            return HomeTile(id: id, size: size)
        }
        guard !restored.isEmpty else { return }
        tiles = restored
        hero = stored.hero.flatMap(ModuleID.init(rawValue:))
        fit(to: modules)
    }

    public var saved: Data {
        let stored = Stored(
            tiles: tiles.map { .init(module: $0.id.rawValue, size: $0.size.rawValue) },
            hero: hero?.rawValue
        )
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    private mutating func fit(to modules: [ModuleID]) {
        tiles.removeAll { !modules.contains($0.id) }
        tiles += modules.filter { id in !tiles.contains { $0.id == id } }.map { HomeTile(id: $0, size: .small) }
        if let hero, !modules.contains(hero) { self.hero = nil }
    }

    public func size(of module: ModuleID) -> TileSize? {
        tiles.first { $0.id == module }?.size
    }

    /// Choosing a size for the big square takes it back to an ordinary tile.
    public mutating func setSize(_ size: TileSize, of module: ModuleID) {
        guard let index = tiles.firstIndex(where: { $0.id == module }) else { return }
        tiles[index].size = size
        if hero == module { hero = nil }
    }

    public mutating func makeHero(_ module: ModuleID) {
        guard size(of: module) != nil else { return }
        hero = module
    }

    /// Takes `target`'s place. That alone can change nothing on screen: a wide tile can't share a row,
    /// so the small tile it passed slides back into the gap beside its neighbour. So this carries on in
    /// the same direction until the tile really moves.
    public mutating func move(_ module: ModuleID, to target: ModuleID) {
        guard module != target, let from = tiles.firstIndex(where: { $0.id == module }),
              let to = tiles.firstIndex(where: { $0.id == target })
        else { return }
        let place = placement(of: module)
        let step = to < from ? -1 : 1
        tiles.insert(tiles.remove(at: from), at: to)
        var index = to
        while placement(of: module) == place, tiles.indices.contains(index + step) {
            tiles.swapAt(index, index + step)
            index += step
        }
    }

    public func canMove(_ module: ModuleID, by step: Int) -> Bool {
        moved(module, by: step) != nil
    }

    public mutating func move(_ module: ModuleID, by step: Int) {
        if let moved = moved(module, by: step) { self = moved }
    }

    /// One place earlier or later as the grid shows it. A small tile can slide straight back into a
    /// gap, so this carries on until the tile really changes place.
    private func moved(_ module: ModuleID, by step: Int) -> HomeLayout? {
        let order = placements.filter { $0.id != hero }.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map(\.id)
        guard var index = order.firstIndex(of: module) else { return nil }
        var shown = self
        var next = order.makeIterator()
        shown.tiles = tiles.map { tile in
            guard tile.id != hero, let id = next.next() else { return tile }
            return tiles.first { $0.id == id } ?? tile
        }
        let place = placement(of: module)
        index += step
        while order.indices.contains(index) {
            var trial = shown
            trial.move(module, to: order[index])
            if trial.placement(of: module) != place { return trial }
            index += step
        }
        return nil
    }

    private func placement(of module: ModuleID) -> TilePlacement? {
        placements.first { $0.id == module }
    }

    /// Every tile's place: the big square first, then the rest in order, each in the first space it
    /// fits. That lets a small tile fill a gap left beside an earlier small tile.
    public var placements: [TilePlacement] {
        var grid = TileGrid()
        var placed = hero.map { [grid.place($0, columns: Self.columns, rows: Self.heroRows)] } ?? []
        for tile in tiles where tile.id != hero {
            placed.append(grid.place(tile.id, columns: tile.size.columns, rows: tile.size.rows))
        }
        return placed
    }

    private struct Stored: Codable {
        struct Tile: Codable {
            let module: String
            let size: String
        }

        let tiles: [Tile]
        let hero: String?
    }
}

private struct TileGrid {
    private var taken = Set<[Int]>()

    mutating func place(_ id: ModuleID, columns: Int, rows: Int) -> TilePlacement {
        var row = 0
        while true {
            for column in 0...(HomeLayout.columns - columns) {
                let cells = (row..<row + rows).flatMap { y in (column..<column + columns).map { [y, $0] } }
                if taken.isDisjoint(with: cells) {
                    taken.formUnion(cells)
                    return TilePlacement(id: id, column: column, row: row, columns: columns, rows: rows)
                }
            }
            row += 1
        }
    }
}

/// Turns places into points. Two rows and the gap between them make a small tile's height, which is
/// what keeps a small tile and the big square exactly square.
public struct BentoMetrics: Equatable, Sendable {
    let gap: CGFloat
    let columnWidth: CGFloat
    let rowHeight: CGFloat

    public init(width: CGFloat, gap: CGFloat = Space.s4) {
        self.gap = gap
        columnWidth = max(0, (width - gap) / CGFloat(HomeLayout.columns))
        rowHeight = max(0, (columnWidth - gap) / 2)
    }

    public func frame(of placement: TilePlacement) -> CGRect {
        CGRect(
            x: CGFloat(placement.column) * (columnWidth + gap),
            y: CGFloat(placement.row) * (rowHeight + gap),
            width: CGFloat(placement.columns) * columnWidth + CGFloat(placement.columns - 1) * gap,
            height: CGFloat(placement.rows) * rowHeight + CGFloat(placement.rows - 1) * gap
        )
    }

    /// The tile under a point, for a hold or a drag.
    public func placement(at point: CGPoint, among placements: [TilePlacement]) -> TilePlacement? {
        placements.first { frame(of: $0).contains(point) }
    }

    public func height(of placements: [TilePlacement]) -> CGFloat {
        placements.map { frame(of: $0).maxY }.max() ?? 0
    }
}
