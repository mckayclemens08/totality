import Foundation
import TotalityCore

/// How a save back to Drive went (issue 102, step 4).
public enum DriveSave: Equatable, Sendable {
    /// Drive has it, as a new revision. The file is now this version.
    case saved(DriveOpenedFile)
    /// Drive's copy changed after it was opened here, so nothing was sent over it. The person chooses
    /// "Keep both" or "Use mine".
    case changedInDrive
}

extension GoogleDrive {
    /// Saves text back over a file opened from a linked folder, as a new Drive revision. Unless `overwrite`,
    /// it first checks Drive's version is still the one opened, and stops if it isn't: a save never
    /// replaces someone else's change without the person saying so.
    public func save(
        _ text: String, over file: DriveOpenedFile, overwrite: Bool = false, limit: Int = DriveCacheLimit.standard
    ) async throws -> DriveSave {
        let entry = try editable(file)
        let (api, token) = try await reader(file.account)
        if !overwrite {
            let current = try await api.entry(entry.id, accessToken: token)
            if current.version != file.version || current.modifiedAt != file.modifiedAt { return .changedInDrive }
        }
        let data = Data(text.utf8)
        let saved = try await api.update(entry.id, data: data, mime: entry.mime, accessToken: token)
        try replace(saved, in: file.folderID, account: file.account)
        let key = Self.key(file.account, entry.id)
        if try reachableFolder(Self.key(file.account, file.folderID)) {
            try keep(data, as: key, entry: saved, mime: file.mime, folderKey: Self.key(file.account, file.folderID), limit: limit)
        }
        return .saved(DriveOpenedFile(
            entry: saved, account: file.account, folderID: file.folderID, data: data, mime: file.mime,
            version: saved.version, modifiedAt: saved.modifiedAt
        ))
    }

    /// "Keep both": what was typed goes into a new file beside the original, which stays as Drive has it.
    public func saveCopy(_ text: String, of file: DriveOpenedFile) async throws -> DriveEntry {
        let entry = try editable(file)
        let (api, token) = try await reader(file.account)
        let created = try await api.create(
            named: Self.copyName(entry.name), in: file.folderID, data: Data(text.utf8), mime: entry.mime, accessToken: token
        )
        _ = try? await refresh(file.folderID, account: file.account)
        return created
    }

    /// "Essay.md" becomes "Essay (from Totality).md".
    static func copyName(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        return ext.isEmpty ? "\(base) (from Totality)" : "\(base) (from Totality).\(ext)"
    }

    /// The file as Drive's listing has it, and only if it's text this account may change.
    private func editable(_ file: DriveOpenedFile) throws -> DriveEntry {
        guard let listing = try kept(file.folderID, account: file.account),
              let entry = listing.entries.first(where: { $0.id == file.entry.id && !$0.isFolder })
        else { throw DriveProblem.notFound }
        guard entry.isEditableText else { throw DriveProblem.notAllowed }
        return entry
    }

    /// Puts what Drive now says about a file into the folder's kept listing.
    private func replace(_ entry: DriveEntry, in folderID: String, account: String) throws {
        let key = Self.key(account, folderID)
        guard let listing = try kept(folderID, account: account), let id = try loadState().listings[key] else { return }
        let entries = listing.entries.map { $0.id == entry.id ? entry : $0 }
        try seal(JSONEncoder().encode(DriveListing(account: listing.account, folderID: folderID, entries: entries, readAt: listing.readAt)), id: id)
    }

    // MARK: Disconnecting

    /// What disconnecting this account also ends, for the screen to say first.
    public func alsoEnds(_ address: String) -> Set<GoogleUse> {
        guard let connection = try? accounts?.connection(address) else { return [] }
        return GoogleUse.uses(of: connection.granted).subtracting([.drive])
    }

    /// Takes Totality's access back at Google, which ends it for every module on that account, and
    /// forgets the account's linked folders, listings and downloaded files here.
    public func disconnect(_ address: String) async throws {
        let address = address.lowercased()
        try? await accounts?.disconnect(address)
        var state = try loadState()
        state.links.removeAll { $0.account == address }
        try saveState(state)
        try prune()
    }
}
