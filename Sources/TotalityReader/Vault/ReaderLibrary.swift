import Foundation

public enum ReaderSort: String, CaseIterable, Sendable {
    case recent, name, type
}

/// The folder tree, built from what's on the device. Sync can leave odd shapes: a folder deleted
/// elsewhere, or two folders moved inside each other on different devices. Nothing may vanish because
/// of that, so anything without a reachable parent shows at the top level.
public struct ReaderLibrary: Sendable, Equatable {
    public let items: [ReaderItem]
    public let folders: [ReaderItem]
    private let folderByID: [UUID: ReaderItem]
    private let looped: Set<UUID>
    private let foldersByParent: [UUID?: [ReaderItem]]
    private let itemsByParent: [UUID?: [ReaderItem]]

    public init(items: [ReaderItem] = [], folders: [ReaderItem] = []) {
        self.items = items
        self.folders = folders
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let looped = Self.loops(in: byID)
        let parent = { (entry: ReaderItem) in Self.parent(of: entry, folders: byID, looped: looped) }
        folderByID = byID
        self.looped = looped
        foldersByParent = Dictionary(grouping: folders, by: parent)
        itemsByParent = Dictionary(grouping: items, by: parent)
    }

    /// The folders that lead back to themselves. Each folder is walked once, however the tree is shaped.
    private static func loops(in folders: [UUID: ReaderItem]) -> Set<UUID> {
        var looped = Set<UUID>()
        var finished = Set<UUID>()
        for start in folders.keys where !finished.contains(start) {
            var walk: [UUID] = []
            var onWalk = Set<UUID>()
            var next: UUID? = start
            while let current = next, folders[current] != nil, !finished.contains(current), onWalk.insert(current).inserted {
                walk.append(current)
                next = folders[current]?.folderID
            }
            if let repeated = next, onWalk.contains(repeated) {
                looped.formUnion(walk.drop { $0 != repeated })
            }
            finished.formUnion(walk)
        }
        return looped
    }

    private static func parent(of entry: ReaderItem, folders: [UUID: ReaderItem], looped: Set<UUID>) -> UUID? {
        guard let parent = entry.folderID, folders[parent] != nil, !looped.contains(entry.id) else { return nil }
        return parent
    }

    public func contents(of folder: UUID?, sortedBy sort: ReaderSort = .recent) -> (folders: [ReaderItem], items: [ReaderItem]) {
        (Self.sorted(foldersByParent[folder] ?? [], by: sort), Self.sorted(itemsByParent[folder] ?? [], by: sort))
    }

    /// Nil means the top level, including when the stored parent can't be reached.
    public func parent(of entry: ReaderItem) -> UUID? {
        Self.parent(of: entry, folders: folderByID, looped: looped)
    }

    /// From the top level down to `folder`, for breadcrumbs.
    public func path(to folder: UUID?) -> [ReaderItem] {
        var path: [ReaderItem] = []
        var next = folder.flatMap { folderByID[$0] }
        while let current = next {
            path.append(current)
            next = parent(of: current).flatMap { folderByID[$0] }
        }
        return path.reversed()
    }

    /// Every item and folder inside, at any depth.
    public func descendants(of folder: UUID) -> [ReaderItem] {
        var found: [ReaderItem] = []
        var waiting = [folder]
        while let next = waiting.popLast() {
            let inside = contents(of: next)
            found += inside.items + inside.folders
            waiting += inside.folders.map(\.id)
        }
        return found
    }

    public func canMove(_ entry: ReaderItem, to destination: UUID?) -> Bool {
        guard let destination else { return true }
        return destination != entry.id && !path(to: destination).contains { $0.id == entry.id }
    }

    private static func sorted(_ entries: [ReaderItem], by sort: ReaderSort) -> [ReaderItem] {
        switch sort {
        case .recent:
            entries.sorted { $0.updatedAt > $1.updatedAt }
        case .name:
            entries.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .type:
            entries.sorted {
                $0.typeName == $1.typeName
                    ? $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
                    : $0.typeName < $1.typeName
            }
        }
    }
}
