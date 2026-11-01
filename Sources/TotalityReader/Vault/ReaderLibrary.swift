import Foundation

/// Earlier builds stored "recent" for last edited. That no longer matches, so it becomes the default.
public enum ReaderSort: String, CaseIterable, Sendable {
    case opened, added, edited, name, type

    public var label: String {
        switch self {
        case .opened: "Recently opened"
        case .added: "Recently added"
        case .edited: "Recently edited"
        case .name: "Name"
        case .type: "Type"
        }
    }
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
    private let opened: [UUID: Date]

    public init(items: [ReaderItem] = [], folders: [ReaderItem] = [], opened: [UUID: Date] = [:]) {
        self.items = items
        self.folders = folders
        self.opened = opened
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

    public func contents(of folder: UUID?, sortedBy sort: ReaderSort = .opened) -> (folders: [ReaderItem], items: [ReaderItem]) {
        (sorted(foldersByParent[folder] ?? [], by: sort), sorted(itemsByParent[folder] ?? [], by: sort))
    }

    public func opening(_ id: UUID, at date: Date) -> ReaderLibrary {
        ReaderLibrary(items: items, folders: folders, opened: opened.merging([id: date]) { _, new in new })
    }

    public var lastOpened: [ReaderItem] {
        sorted(items, by: .opened)
    }

    /// The date a list in this order shows. Opening only counts on this device, so a change from
    /// another device counts too: it means the item was opened there. So does anything never opened.
    public func date(of entry: ReaderItem, sortedBy sort: ReaderSort) -> Date {
        switch sort {
        case .opened: max(opened[entry.id] ?? entry.updatedAt, entry.updatedAt)
        case .added: entry.createdAt
        case .edited, .name, .type: entry.updatedAt
        }
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

    private func sorted(_ entries: [ReaderItem], by sort: ReaderSort) -> [ReaderItem] {
        switch sort {
        case .opened, .added, .edited:
            entries.sorted { date(of: $0, sortedBy: sort) > date(of: $1, sortedBy: sort) }
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
