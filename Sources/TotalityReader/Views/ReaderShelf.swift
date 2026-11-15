import Foundation

/// Something on the Reader's home tile: an item in the library, or a linked Drive folder or a file opened
/// from one (issue 102). Each goes by when it was last opened, whichever it is.
public enum ShelfEntry: Identifiable, Equatable {
    case item(ReaderItem)
    case drive(DriveRecent)

    /// What a tap asks the Reader for. A Drive file's is the ID it opens under, so Listen matches it.
    public var id: UUID {
        switch self {
        case .item(let item): item.id
        case .drive(let recent): DriveModel.shelfID(recent)
        }
    }

    public var title: String {
        switch self {
        case .item(let item): item.displayTitle
        case .drive(let recent): recent.isFolder ? recent.title : DriveModel.title(of: recent.title)
        }
    }

    var systemImage: String {
        switch self {
        case .item(let item): item.systemImage
        case .drive(let recent): recent.isFolder ? "folder" : Self.entry(recent).systemImage
        }
    }

    var typeName: String {
        switch self {
        case .item(let item): item.typeName
        case .drive(let recent): recent.isFolder ? "Google Drive folder" : "\(Self.entry(recent).typeName) in Google Drive"
        }
    }

    private static func entry(_ recent: DriveRecent) -> DriveEntry {
        DriveEntry(id: recent.id, name: recent.title, mime: recent.mime)
    }
}

extension ReaderModel {
    /// How many entries a shelf ever needs: the tile's front book and its row, or the glance's lines.
    private static let shelfDepth = 6

    /// The library and Drive together, last opened first.
    public var shelf: [ShelfEntry] {
        let items = library.lastOpened.prefix(Self.shelfDepth).map { (entry: ShelfEntry.item($0), at: library.date(of: $0, sortedBy: .opened)) }
        let fromDrive = (drive?.recent ?? []).prefix(Self.shelfDepth).map { (entry: ShelfEntry.drive($0), at: $0.openedAt) }
        return (items + fromDrive).sorted { $0.at > $1.at }.map(\.entry)
    }

    /// Where a Drive entry on the tile opens. Nil when `id` isn't a Drive entry; an inner nil when it is,
    /// but its folder no longer lists it.
    func openDriveShelfEntry(_ id: UUID) async -> ReaderRoute?? {
        guard let drive, let recent = drive.recent.first(where: { DriveModel.shelfID($0) == id }) else { return nil }
        switch await drive.target(of: recent) {
        case .folder(let account, let folderID, let name):
            return .some(.drive(DriveLocation(account: account, folderID: folderID, name: name)))
        case .file(let account, let folderID, let entry):
            let name = drive.links.first { $0.account == account && $0.folderID == folderID }?.name ?? ""
            return .some(.driveFile(DriveFileRoute(location: DriveLocation(account: account, folderID: folderID, name: name), entry: entry)))
        case nil:
            return .some(nil)
        }
    }
}
