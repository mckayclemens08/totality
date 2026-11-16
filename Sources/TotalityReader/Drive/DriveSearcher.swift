import Foundation
import TotalityCore

/// Home search inside linked Drive folders, beside the Reader's own library. It's two searchers so the
/// names kept on the device show at once, and Google's answer about contents joins them when it comes.
/// Both answer as the Reader, and home search puts their results in the Reader's group.
public struct DriveSearcher: ModuleSearcher {
    public enum Part: Sendable {
        /// File names in the listings kept on this device. Nothing leaves the device.
        case names
        /// What's inside files, asked of Google Drive's own search.
        case contents
    }

    public let module = ModuleID.reader
    public let kinds: Set<ContentKind> = []
    private let drive: GoogleDrive
    private let part: Part
    /// How long typing has to stop before Google is asked, on top of home search's own pause.
    private let pause: Duration

    init(drive: GoogleDrive, part: Part, pause: Duration = .milliseconds(350)) {
        self.drive = drive
        self.part = part
        self.pause = pause
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let found: [DriveSearchHit]
        switch part {
        case .names:
            found = (try? await drive.searchNames(query)) ?? []
        case .contents:
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return [] }
            found = await drive.searchContents(query)
        }
        return found.map(Self.hit)
    }

    static func hit(_ found: DriveSearchHit) -> SearchHit {
        SearchHit(
            module: .reader, itemID: itemID(found), title: DriveModel.title(of: found.entry.name),
            detail: "\(found.entry.typeName) in Google Drive", date: found.entry.modifiedAt
        )
    }

    // MARK: What a result's ID holds

    static let prefix = "gdrive/"

    /// `gdrive/<file>/<folder,folder,…>/<account>`. Drive's IDs never hold "/" or ",", and the account
    /// goes last, so whatever's in an address can't move the rest.
    static func itemID(_ found: DriveSearchHit) -> String {
        prefix + found.entry.id + "/" + found.folders.joined(separator: ",") + "/" + found.account
    }

    /// Nil for anything that isn't a Drive result, or doesn't check out.
    public static func parse(_ itemID: String) -> (fileID: String, folders: [String], account: String)? {
        guard itemID.hasPrefix(prefix) else { return nil }
        let parts = itemID.dropFirst(prefix.count).split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, DriveAPI.isID(parts[0]), !parts[2].isEmpty else { return nil }
        let folders = parts[1].split(separator: ",").map(String.init)
        guard !folders.isEmpty, folders.count <= GoogleDrive.deepestSearch, folders.allSatisfy(DriveAPI.isID) else { return nil }
        return (parts[0], folders, parts[2])
    }
}

extension DriveModel {
    /// Home search's searchers for linked Drive folders.
    public var searchers: [any ModuleSearcher] {
        [DriveSearcher(drive: drive, part: .names), DriveSearcher(drive: drive, part: .contents)]
    }
}
