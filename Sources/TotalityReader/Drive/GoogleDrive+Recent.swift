import Foundation
import TotalityCore

/// A Drive file opened in the Reader, or a linked folder, for the Reader's home tile. It's kept sealed in
/// the Drive state with the content key, like the library's own opened dates, and holds only what the
/// tile shows and needs to open it again.
public struct DriveRecent: Codable, Equatable, Hashable, Sendable {
    /// Drive's ID for the file or folder.
    public let id: String
    public let account: String
    public let title: String
    /// Drive's own kind for it, so the tile can name it.
    public let mime: String
    public var openedAt: Date

    public var isFolder: Bool { mime == DriveEntry.folderMime }

    var key: String { GoogleDrive.key(account, id) }
}

extension GoogleDrive {
    /// How many opened files are remembered. The tile shows a few at most.
    static let mostRecent = 20

    /// Remembers that a file listed inside a linked folder was opened.
    func noteOpened(_ entry: DriveEntry, account: String) throws {
        var state = try loadState()
        let recent = DriveRecent(id: entry.id, account: account.lowercased(), title: entry.name, mime: entry.mime, openedAt: now())
        state.recent.removeAll { $0.key == recent.key }
        state.recent.insert(recent, at: 0)
        // Folders don't count against files: every linked folder stays, however many files were opened.
        var files = 0
        state.recent.removeAll { entry in
            guard !entry.isFolder else { return false }
            files += 1
            return files > Self.mostRecent
        }
        try saveState(state)
    }

    /// Remembers that a linked folder was opened. Any other folder is only browsed, and isn't kept.
    public func noteOpenedFolder(_ folderID: String, account: String) throws {
        guard !isClosed else { throw ReaderError.closed }
        let account = account.lowercased()
        var state = try loadState()
        guard let link = state.links.first(where: { $0.account == account && $0.folderID == folderID }) else { return }
        state.recent.removeAll { $0.key == Self.key(account, folderID) }
        state.recent.insert(DriveRecent(id: folderID, account: account, title: link.name, mime: DriveEntry.folderMime, openedAt: now()), at: 0)
        try saveState(state)
    }

    /// Every linked folder, and the files opened from them, newest first. A folder never opened counts
    /// from when it was linked. Files only of connected accounts.
    public func recent() throws -> [DriveRecent] {
        guard !isClosed else { throw ReaderError.closed }
        let state = try loadState()
        let connected = Set(try connections().map(\.address))
        let opened = Dictionary(state.recent.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // Folders of accounts not connected here still show, as "Connect to see".
        let folders = state.links.map { link in
            opened[Self.key(link.account, link.folderID)].map { DriveRecent(id: link.folderID, account: link.account, title: link.name, mime: DriveEntry.folderMime, openedAt: $0.openedAt) }
                ?? DriveRecent(id: link.folderID, account: link.account, title: link.name, mime: DriveEntry.folderMime, openedAt: link.linkedAt)
        }
        // A file stays on the tile even when this device holds no listing of its folder, such as one opened
        // from home search: the owner wants opened Drive files kept beside the folders (2026-11-16). Where it
        // is gets found again when it's tapped.
        let files = state.recent.filter { !$0.isFolder && connected.contains($0.account) }
        return (folders + files).sorted { $0.openedAt > $1.openedAt }
    }

    /// Where a file opened before is now: the folder inside a linked one that lists it, and its entry.
    public func whereIs(_ fileID: String, account: String) throws -> (folderID: String, entry: DriveEntry)? {
        guard !isClosed else { throw ReaderError.closed }
        return listedFiles(in: try loadState())[Self.key(account, fileID)]
    }

    /// Every file in a kept listing inside a linked folder, or inside `roots`, by `"account/fileID"`.
    func listedFiles(in state: State, under roots: [String]? = nil) -> [String: (folderID: String, entry: DriveEntry)] {
        var found: [String: (folderID: String, entry: DriveEntry)] = [:]
        for key in reachable(in: state, from: roots) {
            guard let id = state.listings[key], let plain = try? open(id),
                  let listing = try? JSONDecoder().decode(DriveListing.self, from: plain),
                  Self.key(listing.account, listing.folderID) == key
            else { continue }
            for entry in listing.entries where !entry.isFolder {
                found[Self.key(listing.account, entry.id)] = (listing.folderID, entry)
            }
        }
        return found
    }

    /// What `prune` keeps: folders only while they're linked. Files stay even when this device hasn't
    /// listed their folder yet, because the record is shared and another device may have; the tile shows
    /// only those listed here. Unlinking and disconnecting remove files themselves.
    func prunedRecent(_ state: State) -> [DriveRecent] {
        let linked = Set(state.links.map { Self.key($0.account, $0.folderID) })
        return state.recent.filter { !$0.isFolder || linked.contains($0.key) }
    }
}
