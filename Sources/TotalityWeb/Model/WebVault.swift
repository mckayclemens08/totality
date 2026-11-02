import CryptoKit
import Foundation
import TotalityCore

public struct WebBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL
    /// Empty means it isn't in a folder.
    public var folder: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, folder: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.folder = folder
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        title.isEmpty ? url.host() ?? url.absoluteString : title
    }
}

public struct WebVisit: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let url: URL
    public var date: Date

    public init(id: UUID = UUID(), title: String, url: URL, date: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.date = date
    }

    public var displayTitle: String {
        title.isEmpty ? url.host() ?? url.absoluteString : title
    }
}

public struct WebSavedTabs: Codable, Equatable, Sendable {
    public struct Tab: Codable, Equatable, Sendable {
        public let id: UUID
        public let url: URL
        public let title: String
    }

    public var tabs: [Tab] = []
    public var current: UUID?
}

/// What belongs to one account on this device, sealed with the device's key.
public struct WebSettings: Codable, Equatable, Sendable {
    /// Sites the person turned blocking off for.
    public var unblockedSites: Set<String> = []
}

public enum WebVaultError: Error, Equatable {
    case notFound, mismatched, closed
}

/// Bookmarks are one blob each and sync. History, open tabs, and settings stay on this device, one set
/// for each account. All of it is sealed, because addresses and page titles count as content. A device
/// has one content key, so the key doesn't keep two accounts apart: the IDs do. Blob names hold only IDs.
public actor WebVault {
    public static let sealedPurposes: [String: KeyPurpose] = [
        ".bookmark": .bookmark, ".bookmark.trash": .bookmark, ".browsing": .browsing,
    ]
    public static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// The same every launch and different for every account, so nothing has to be stored to find it.
    private static func id(_ name: String, for account: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("totality.web.\(name).\(account)".utf8)).prefix(16))
        // WebKit takes only a well-formed UUID as a store's name.
        bytes[6] = bytes[6] & 0x0f | 0x40
        bytes[8] = bytes[8] & 0x3f | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    /// Names one account's store of cookies and site data, and its downloads folder.
    public static func siteID(for account: String) -> UUID {
        id("site", for: account)
    }

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var isClosed = false
    private var hashes: [UUID: String] = [:]

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    private func name(_ id: UUID) -> String { "\(id.uuidString.lowercased()).bookmark" }
    private func deletionName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).deleted" }
    private func browsingName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).browsing" }
    private func trashStampName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).trashed" }

    public func close() {
        isClosed = true
    }

    public func save(_ bookmark: WebBookmark) throws {
        guard !isClosed else { throw WebVaultError.closed }
        hashes[bookmark.id] = nil
        let key = rootKey.objectKey(for: bookmark.id, purpose: .bookmark)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(bookmark), key: key, objectID: bookmark.id), as: name(bookmark.id))
    }

    public func bookmark(_ id: UUID) throws -> WebBookmark {
        guard let sealed = try store.read(name(id)) else { throw WebVaultError.notFound }
        let key = rootKey.objectKey(for: id, purpose: .bookmark)
        let bookmark = try JSONDecoder().decode(WebBookmark.self, from: ContentCipher.open(sealed, key: key, objectID: id))
        guard bookmark.id == id else { throw WebVaultError.mismatched }
        return bookmark
    }

    /// One that won't open is left out. It stays on disk, so a sync or a key move can still reach it.
    public func bookmarks() throws -> [WebBookmark] {
        var found: [WebBookmark] = []
        for file in try store.names() where file.hasSuffix(".bookmark") {
            guard let id = UUID(uuidString: String(file.dropLast(".bookmark".count))) else { continue }
            if let bookmark = try? self.bookmark(id) { found.append(bookmark) }
        }
        return found.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID) throws {
        guard !isClosed else { throw WebVaultError.closed }
        // The record goes first, so a crash can't lose the fact that this was deleted on purpose.
        try store.write(Data(), as: deletionName(id))
        try store.delete(name(id))
        hashes[id] = nil
    }

    private func write<Value: Encodable>(_ value: Value, id: UUID) throws {
        guard !isClosed else { throw WebVaultError.closed }
        let key = rootKey.objectKey(for: id, purpose: .browsing)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(value), key: key, objectID: id), as: browsingName(id))
    }

    private func read<Value: Decodable>(_ type: Value.Type, id: UUID) throws -> Value? {
        guard let sealed = try store.read(browsingName(id)) else { return nil }
        let key = rootKey.objectKey(for: id, purpose: .browsing)
        return try JSONDecoder().decode(type, from: ContentCipher.open(sealed, key: key, objectID: id))
    }

    private func remove(id: UUID) throws {
        guard !isClosed else { throw WebVaultError.closed }
        try store.delete(browsingName(id))
    }

    public func history(for account: String) throws -> [WebVisit] {
        try read([WebVisit].self, id: Self.id("history", for: account)) ?? []
    }

    /// Nothing is left behind by an empty list, so a device nobody has really used stays empty.
    public func saveHistory(_ visits: [WebVisit], for account: String) throws {
        let id = Self.id("history", for: account)
        if visits.isEmpty { try remove(id: id) } else { try write(visits, id: id) }
    }

    public func savedTabs(for account: String) throws -> WebSavedTabs {
        try read(WebSavedTabs.self, id: Self.id("tabs", for: account)) ?? WebSavedTabs()
    }

    public func saveTabs(_ tabs: WebSavedTabs, for account: String) throws {
        let id = Self.id("tabs", for: account)
        if tabs.tabs.isEmpty { try remove(id: id) } else { try write(tabs, id: id) }
    }

    public func settings(for account: String) throws -> WebSettings {
        try read(WebSettings.self, id: Self.id("settings", for: account)) ?? WebSettings()
    }

    public func saveSettings(_ settings: WebSettings, for account: String) throws {
        try write(settings, id: Self.id("settings", for: account))
    }
}

extension WebVault: SyncArea {
    /// Only bookmarks. History, tabs, and settings have no kind here, so sync can never see them.
    public nonisolated var kinds: Set<ContentKind> { [.bookmark] }

    public func sealedObjectIDs() throws -> [UUID] {
        // A crash can stop a delete halfway. The record says what was meant, so finish it.
        if !isClosed {
            for id in try deletedObjectIDs() where try store.read(name(id)) != nil {
                try store.delete(name(id))
                hashes[id] = nil
            }
        }
        return try store.names().compactMap { file in
            file.hasSuffix(".bookmark") ? UUID(uuidString: String(file.dropLast(".bookmark".count))) : nil
        }
    }

    public func sealedHash(of id: UUID) throws -> String? {
        if let known = hashes[id] { return known }
        let hash = try sealedObject(id)?.hash
        hashes[id] = hash
        return hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        try store.read(name(id)).map { SealedObject(id: id, kind: .bookmark, meta: $0, body: nil) }
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        _ = try opened(object)
        return object
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw WebVaultError.closed }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        if expected == nil, try store.read(deletionName(object.id)) != nil { throw SyncError.changedLocally }
        _ = try opened(object)
        try store.write(object.meta, as: name(object.id))
        hashes[object.id] = nil
    }

    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {
        guard !isClosed else { throw WebVaultError.closed }
        guard try sealedHash(of: id) == expected else { throw SyncError.changedLocally }
        guard let sealed = try store.read(name(id)) else { return }
        // The stamp goes first, so a crash can't leave trash that's never cleaned up.
        try store.write(Data(ISO8601DateFormatter().string(from: Date()).utf8), as: trashStampName(id))
        try store.write(sealed, as: name(id) + ".trash")
        try store.delete(name(id))
        hashes[id] = nil
    }

    public func emptyOldTrash() throws {
        guard !isClosed else { return }
        let formatter = ISO8601DateFormatter()
        for file in try store.names() where file.hasSuffix(".trashed") {
            guard let id = UUID(uuidString: String(file.dropLast(".trashed".count))),
                  let stamp = try store.read(file), let date = formatter.date(from: String(decoding: stamp, as: UTF8.self)),
                  Date().timeIntervalSince(date) > Self.trashLifetime
            else { continue }
            try store.delete(name(id) + ".trash")
            try store.delete(file)
        }
    }

    public func deletedObjectIDs() throws -> Set<UUID> {
        Set(try store.names().compactMap { file in
            file.hasSuffix(".deleted") ? UUID(uuidString: String(file.dropLast(".deleted".count))) : nil
        })
    }

    public func clearDeletion(_ id: UUID) throws {
        try store.delete(deletionName(id))
    }

    /// The newest wins. A bookmark is too small to be worth keeping a conflict copy of.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        try opened(local).updatedAt >= opened(remote).updatedAt ? .keepLocal : .keepRemote
    }

    private func opened(_ object: SealedObject) throws -> WebBookmark {
        let key = rootKey.objectKey(for: object.id, purpose: .bookmark)
        let bookmark = try JSONDecoder().decode(WebBookmark.self, from: ContentCipher.open(object.meta, key: key, objectID: object.id))
        guard bookmark.id == object.id else { throw CryptoError.authenticationFailed }
        return bookmark
    }
}
