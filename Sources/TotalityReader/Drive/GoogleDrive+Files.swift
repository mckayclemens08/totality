import Foundation
import TotalityCore

/// A Drive file kept on the device after it was opened (issue 102, step 3).
struct CachedFile: Codable, Equatable, Sendable {
    /// The sealed blob's random ID, so storage shows nothing about which file it is.
    let blob: UUID
    /// The folder it was opened from, as `"account/folderID"`, so unlinking clears it.
    let folderKey: String
    /// Drive's version and change time when it was downloaded. Either moving on means download again.
    let version: String?
    let modifiedAt: Date?
    let mime: String
    let bytes: Int
    var openedAt: Date
}

/// A Drive file, opened: its bytes in memory, and what kind of file the Reader should treat it as.
public struct DriveOpenedFile: Sendable, Equatable {
    public let entry: DriveEntry
    public let account: String
    public let folderID: String
    public let data: Data
    /// What the Reader's viewers read it as. A Google Doc comes as Markdown, and Sheets or Slides as PDF.
    public let mime: String
    /// The Drive version it is, which a save checks against (step 4).
    public let version: String?
    public let modifiedAt: Date?
}

/// How much opened files may take on this device.
public enum DriveCacheLimit {
    public static let choices: [Int] = [100, 250, 500, 1_000, 2_000].map { $0 * 1_000_000 }
    public static let standard = 500 * 1_000_000
}

extension GoogleDrive {
    /// The biggest file that's opened. The viewers hold a file in memory whole.
    static let mostFileBytes = 100 * 1_000_000

    static let fileSuffix = ".gdfile"
    static func fileName(_ id: UUID) -> String { id.uuidString.lowercased() + fileSuffix }

    /// What the Reader opens a Drive file as, or nil for something it can't show.
    static func readerMime(for entry: DriveEntry) -> (export: String?, opensAs: String)? {
        switch entry.mime {
        case DriveEntry.googleDocMime: return ("text/markdown", MarkdownText.mime)
        case "application/vnd.google-apps.spreadsheet", "application/vnd.google-apps.presentation",
             "application/vnd.google-apps.drawing":
            return ("application/pdf", "application/pdf")
        case _ where entry.isGoogleFormat: return nil
        case "text/markdown", "text/x-markdown": return (nil, MarkdownText.mime)
        case "application/octet-stream" where entry.name.lowercased().hasSuffix(".md"): return (nil, MarkdownText.mime)
        default: return (nil, entry.mime)
        }
    }

    // MARK: Opening

    /// Opens a file listed in a folder inside a linked one. A copy kept from before opens without
    /// asking Google, unless Drive's listing says it changed since. Otherwise it's downloaded, sealed with
    /// the content key, and kept, oldest-opened going first once past `limit`.
    public func file(_ fileID: String, in folderID: String, account: String, limit: Int) async throws -> DriveOpenedFile {
        let account = account.lowercased()
        // Only a file in a folder that can be read: the listing is the one Drive gave, not the caller's word.
        guard let listing = try kept(folderID, account: account),
              let entry = listing.entries.first(where: { $0.id == fileID && !$0.isFolder })
        else { throw DriveProblem.notFound }
        guard let kind = Self.readerMime(for: entry) else { throw ReaderError.notReadable }
        if let size = entry.size, size > Self.mostFileBytes { throw DriveProblem.tooLarge }
        let key = Self.key(account, fileID)
        let folderKey = Self.key(account, folderID)

        if let kept = try keptFile(key, matching: entry) {
            return DriveOpenedFile(
                entry: entry, account: account, folderID: folderID, data: kept, mime: kind.opensAs,
                version: entry.version, modifiedAt: entry.modifiedAt
            )
        }

        let (api, token) = try await reader(account)
        let data = try await api.download(entry, exportingAs: kind.export, accessToken: token)
        guard data.count <= Self.mostFileBytes else { throw DriveProblem.tooLarge }
        // Unlinked while it downloaded: shown this once, but not kept.
        if try reachableFolder(folderKey) {
            try keep(data, as: key, entry: entry, mime: kind.opensAs, folderKey: folderKey, limit: limit)
        }
        return DriveOpenedFile(
            entry: entry, account: account, folderID: folderID, data: data, mime: kind.opensAs,
            version: entry.version, modifiedAt: entry.modifiedAt
        )
    }

    /// The bytes of a kept copy that's still Drive's latest, or nil. One that won't open is dropped.
    private func keptFile(_ key: String, matching entry: DriveEntry) throws -> Data? {
        var state = try loadState()
        guard let cached = state.files[key], let cache else { return nil }
        let current = cached.version == entry.version && cached.modifiedAt == entry.modifiedAt
        guard current, let sealed = try cache.read(Self.fileName(cached.blob)),
              let plain = try? ContentCipher.open(sealed, key: fileKey(cached.blob), objectID: cached.blob)
        else {
            try cache.delete(Self.fileName(cached.blob))
            state.files[key] = nil
            try saveState(state)
            return nil
        }
        state.files[key]?.openedAt = now()
        try saveState(state)
        return plain
    }

    private func keep(_ data: Data, as key: String, entry: DriveEntry, mime: String, folderKey: String, limit: Int) throws {
        guard let cache else { return }
        var state = try loadState()
        if let old = state.files[key] {
            try cache.delete(Self.fileName(old.blob))
            state.files[key] = nil
        }
        // One file bigger than the whole allowance is shown, not kept.
        guard data.count <= limit else {
            try saveState(state)
            return
        }
        let blob = UUID()
        guard !isClosed else { throw ReaderError.closed }
        try cache.write(try ContentCipher.seal(data, key: fileKey(blob), objectID: blob), as: Self.fileName(blob))
        state.files[key] = CachedFile(
            blob: blob, folderKey: folderKey, version: entry.version, modifiedAt: entry.modifiedAt,
            mime: mime, bytes: data.count, openedAt: now()
        )
        try saveState(Self.evicting(state, to: limit, keeping: key, cache: cache))
    }

    /// Drops the least recently opened files until what's kept fits. The one just opened stays.
    static func evicting(_ state: State, to limit: Int, keeping key: String?, cache: any BlobStore) throws -> State {
        var state = state
        var total = state.files.values.reduce(0) { $0 + $1.bytes }
        for (name, file) in state.files.sorted(by: { $0.value.openedAt < $1.value.openedAt }) where total > limit && name != key {
            try cache.delete(fileName(file.blob))
            state.files[name] = nil
            total -= file.bytes
        }
        return state
    }

    private func fileKey(_ blob: UUID) -> ObjectKey {
        rootKey.objectKey(for: blob, purpose: .googleDriveFile)
    }

    // MARK: The cache as a whole

    /// How much opened files take on this device.
    public func cachedBytes() throws -> Int {
        try loadState().files.values.reduce(0) { $0 + $1.bytes }
    }

    /// For a smaller allowance chosen in settings.
    public func trimCache(to limit: Int) throws {
        guard let cache else { return }
        try saveState(Self.evicting(try loadState(), to: limit, keeping: nil, cache: cache))
    }

    /// Clears every opened file. Linked folders and their listings stay.
    public func clearCache() throws {
        var state = try loadState()
        state.files = [:]
        try saveState(state)
        try sweepCache()
    }

    /// Removes anything in the cache folder the state doesn't name: what another person's key left
    /// behind, or a half-written file from a crash. Nothing there can be opened with this key anyway.
    public func sweepCache() throws {
        guard let cache else { return }
        let named = Set(try loadState().files.values.map { Self.fileName($0.blob) })
        for name in try cache.names() where !named.contains(name) {
            try cache.delete(name)
        }
    }
}
