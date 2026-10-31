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

    public init(items: [ReaderItem] = [], folders: [ReaderItem] = []) {
        self.items = items
        self.folders = folders
        folderByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func contents(of folder: UUID?, sortedBy sort: ReaderSort = .recent) -> (folders: [ReaderItem], items: [ReaderItem]) {
        (
            Self.sorted(folders.filter { parent(of: $0) == folder }, by: sort),
            Self.sorted(items.filter { parent(of: $0) == folder }, by: sort)
        )
    }

    /// Nil means the top level, including when the stored parent can't be reached.
    public func parent(of entry: ReaderItem) -> UUID? {
        guard let parent = entry.folderID, folderByID[parent] != nil, !isInLoop(entry.id) else { return nil }
        return parent
    }

    private func isInLoop(_ id: UUID) -> Bool {
        var seen = Set<UUID>()
        var next = folderByID[id]?.folderID
        while let current = next, seen.insert(current).inserted {
            if current == id { return true }
            next = folderByID[current]?.folderID
        }
        return false
    }

    /// From the top level down to `folder`, for breadcrumbs.
    public func path(to folder: UUID?) -> [ReaderItem] {
        var path: [ReaderItem] = []
        var next = folder.flatMap { folderByID[$0] }
        while let current = next {
            path.insert(current, at: 0)
            next = parent(of: current).flatMap { folderByID[$0] }
        }
        return path
    }

    /// Every item and folder inside, at any depth.
    public func descendants(of folder: UUID) -> [ReaderItem] {
        let inside = contents(of: folder)
        return inside.items + inside.folders + inside.folders.flatMap { descendants(of: $0.id) }
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
