import Foundation
import TotalityCore

/// A file in a linked Drive folder that home search found.
public struct DriveSearchHit: Sendable, Equatable {
    public let account: String
    public let entry: DriveEntry
    /// The folders from the one the file is in up to one that can already be read here, which is a
    /// linked folder or inside one. Opening the file reads each of them from the top down first.
    public let folders: [String]
    /// True when Drive's search found it by what's inside, rather than its name matching.
    public let byContents: Bool

    public var folderID: String { folders.first ?? "" }
}

/// Home search inside linked Drive folders (issue 127 follow-up). Names are matched against the listings
/// kept on this device, so they're found straight away and offline. Contents are asked of Google Drive's
/// own search, which means the words typed go from this device to Google, and only there: it's the
/// person's own Drive, and nothing goes to Totality's server. Only files whose folders lead up to a linked
/// folder are kept, whatever else Drive finds. An account that's disconnected, or hasn't allowed Drive, is
/// skipped without a word.
extension GoogleDrive {
    static let mostSearchHits = 20
    /// How far up a found file's folders are followed, and how many folders one search may look up.
    static let deepestSearch = 8
    static let mostParentLookups = 20

    /// Accounts that can be searched: connected here, allowing Drive, and with a linked folder.
    private func searchableAccounts(_ state: State) -> Set<String> {
        let allowed = Set(connections().filter(\.allowsDrive).map { $0.address.lowercased() })
        return Set(state.links.map { $0.account.lowercased() }).intersection(allowed)
    }

    /// Files in kept listings whose name has every word, newest first.
    public func searchNames(_ query: String) throws -> [DriveSearchHit] {
        guard !isClosed else { throw ReaderError.closed }
        let terms = SearchText.terms(in: query)
        guard !terms.isEmpty else { return [] }
        let state = try loadState()
        let accounts = searchableAccounts(state)
        let found = listedFiles(in: state).compactMap { key, place -> DriveSearchHit? in
            let account = String(key[..<(key.lastIndex(of: "/") ?? key.endIndex)])
            guard accounts.contains(account), terms.allSatisfy({ SearchText.find($0, in: place.entry.name) != nil }) else { return nil }
            return DriveSearchHit(account: account, entry: place.entry, folders: [place.folderID], byContents: false)
        }
        return Array(found.sorted(by: Self.newestFirst).prefix(Self.mostSearchHits))
    }

    /// Files whose contents Drive's search matched, in linked folders only. Nothing's kept from a search.
    public func searchContents(_ query: String) async -> [DriveSearchHit] {
        let terms = SearchText.terms(in: query)
        guard !terms.isEmpty, !isClosed, let state = try? loadState() else { return [] }
        let readable = reachable(in: state)
        var hits: [DriveSearchHit] = []
        var lookups = 0
        for account in searchableAccounts(state).sorted() {
            guard let (api, token) = try? await reader(account),
                  let found = try? await api.search(terms, accessToken: token)
            else { continue }
            var paths: [String: [String]?] = [:]
            for (entry, parents) in found {
                guard Self.readerMime(for: entry) != nil else { continue }
                for parent in parents {
                    if let path = await path(from: parent, account: account, readable: readable, api: api, token: token, known: &paths, lookups: &lookups) {
                        hits.append(DriveSearchHit(account: account, entry: entry, folders: path, byContents: true))
                        break
                    }
                }
            }
        }
        return Array(hits.sorted(by: Self.newestFirst).prefix(Self.mostSearchHits))
    }

    /// The folders from `folder` up to one that can be read here, or nil when there's none within reach.
    private func path(
        from folder: String, account: String, readable: Set<String>, api: DriveAPI, token: String,
        known: inout [String: [String]?], lookups: inout Int
    ) async -> [String]? {
        var path: [String] = []
        var current = folder
        while path.count < Self.deepestSearch {
            path.append(current)
            if readable.contains(Self.key(account, current)) {
                for index in path.indices { known[path[index]] = .some(Array(path[index...])) }
                return path
            }
            if let cached = known[current] {
                guard let rest = cached else { break }
                let whole = path.dropLast() + rest
                for index in whole.indices { known[whole[index]] = .some(Array(whole[index...])) }
                return Array(whole)
            }
            guard lookups < Self.mostParentLookups, let parents = try? await api.parents(of: current, accessToken: token) else { break }
            lookups += 1
            // A folder in several places: the first that's in Drive's answer is followed.
            guard let up = parents.first else { break }
            current = up
        }
        // Not within reach, so the next file in these folders doesn't ask again.
        for id in path { known[id] = .some(nil) }
        return nil
    }

    /// Gets a found file ready to open: reads each of its folders from the top down, unless the file's own
    /// folder is kept and lists it already, and gives back its entry as that listing has it. Every step goes
    /// through `refresh`, which reads only folders inside a linked one, so an ID from anywhere else gets
    /// nowhere.
    public func prepareFound(_ fileID: String, folders: [String], account: String) async throws -> DriveEntry {
        guard let folderID = folders.first, folders.count <= Self.deepestSearch, folders.allSatisfy(DriveAPI.isID), DriveAPI.isID(fileID) else {
            throw DriveProblem.notFound
        }
        func listed() throws -> DriveEntry? {
            try kept(folderID, account: account)?.entries.first { $0.id == fileID && !$0.isFolder }
        }
        if let entry = try listed() { return entry }
        // The top folder can already be read. Listing it makes the next one down readable, and so on.
        for folder in folders.reversed() {
            try await refresh(folder, account: account)
        }
        guard let entry = try listed() else { throw DriveProblem.notFound }
        return entry
    }

    private static func newestFirst(_ one: DriveSearchHit, _ other: DriveSearchHit) -> Bool {
        let a = one.entry.modifiedAt ?? .distantPast, b = other.entry.modifiedAt ?? .distantPast
        return a != b ? a > b : (one.account, one.entry.id) < (other.account, other.entry.id)
    }
}
