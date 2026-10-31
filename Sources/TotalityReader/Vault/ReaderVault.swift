import Foundation
import TotalityCore

public struct ReaderListing: Sendable, Equatable {
    public let items: [ReaderItem]
    /// Items whose metadata would not decrypt. The UI says so instead of hiding them.
    public let unreadable: Int
}

public struct ReaderSearchHit: Sendable, Equatable, Identifiable {
    public let item: ReaderItem
    public let snippet: String?

    public var id: UUID { item.id }
}

/// A snapshot for one grantee, sealed under its own random key. See "Sharing an item" in
/// docs/module-contracts.md.
public struct ReaderShare: Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public let kind: ReaderItem.Kind
        public let title: String
        public let mime: String?
    }

    public let objectID: UUID
    public let wrappedKey: Data
    public let sealedHeader: Data
    public let sealedBody: Data

    public func open(with identity: IdentityKeys) throws -> (header: Header, body: Data) {
        let key = try identity.open(wrappedKey)
        let header = try JSONDecoder().decode(Header.self, from: ContentCipher.open(sealedHeader, key: key, objectID: objectID))
        return (header, try ContentCipher.open(sealedBody, key: key, objectID: objectID))
    }
}

/// How a save from an open note went.
public enum NoteSave: Sendable, Equatable {
    case saved(ReaderItem)
    /// The note changed somewhere else first, so what was typed became a copy and nothing was lost.
    case keptAsCopy(ReaderItem)
}

/// A user's Reader content. Each item is two blobs: metadata and body, under separate per-object
/// keys. Blob names hold only the object ID.
public actor ReaderVault {
    /// Under Supabase's 50 MB upload limit, leaving room for what sealing adds.
    public static let maxImportBytes = 49 * 1024 * 1024
    /// How each kind of blob is sealed, so a key change can reach them without knowing what they are.
    public static let sealedPurposes: [String: KeyPurpose] = [
        ".meta": .metadata, ".body": .content, ".meta.trash": .metadata, ".body.trash": .content,
    ]
    /// How long something removed by another device stays recoverable here.
    public static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let snippetRadius = 60

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var textCache: [UUID: String] = [:]
    private var isClosed = false
    private var hashes: [UUID: String] = [:]

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    private func metaName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).meta" }
    private func deletionName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).deleted" }
    private func bodyName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).body" }

    /// Refuses all further writes. A key move lists every blob once, so anything written after that,
    /// sealed under the old key, would be lost when the old key goes.
    public func close() {
        isClosed = true
    }

    private func writeMeta(_ item: ReaderItem) throws {
        guard !isClosed else { throw ReaderError.closed }
        hashes[item.id] = nil
        let key = rootKey.objectKey(for: item.id, purpose: .metadata)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(item), key: key, objectID: item.id), as: metaName(item.id))
    }

    private func writeBody(_ data: Data, id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
        hashes[id] = nil
        let key = rootKey.objectKey(for: id, purpose: .content)
        try store.write(try ContentCipher.seal(data, key: key, objectID: id), as: bodyName(id))
        textCache[id] = nil
    }

    public func item(_ id: UUID) throws -> ReaderItem {
        guard let sealed = try store.read(metaName(id)) else { throw ReaderError.notFound }
        let key = rootKey.objectKey(for: id, purpose: .metadata)
        return try JSONDecoder().decode(ReaderItem.self, from: ContentCipher.open(sealed, key: key, objectID: id))
    }

    public func list() throws -> ReaderListing {
        var items: [ReaderItem] = []
        var unreadable = 0
        for name in try store.names() where name.hasSuffix(".meta") {
            guard let id = UUID(uuidString: String(name.dropLast(".meta".count))) else { continue }
            do {
                items.append(try item(id))
            } catch is CryptoError, is DecodingError {
                unreadable += 1
            }
        }
        return ReaderListing(items: items.sorted { $0.updatedAt > $1.updatedAt }, unreadable: unreadable)
    }

    public func createNote(title: String = "", collection: String? = nil) throws -> ReaderItem {
        let now = Date()
        let item = ReaderItem(
            id: UUID(), kind: .note, title: title, collection: collection, mime: "text/plain",
            byteCount: 0, createdAt: now, updatedAt: now, listenPosition: 0
        )
        try writeBody(Data(), id: item.id)
        try writeMeta(item)
        return item
    }

    /// Reads the latest metadata first, so saving a note never undoes a newer Listen position.
    @discardableResult
    public func saveNote(_ id: UUID, title: String, body: String) throws -> ReaderItem {
        var updated = try item(id)
        guard updated.kind == .note else { throw ReaderError.notANote }
        let data = Data(body.utf8)
        updated.title = title
        updated.byteCount = data.count
        updated.updatedAt = Date()
        try writeBody(data, id: id)
        try writeMeta(updated)
        return updated
    }

    /// For an open note. `basedOn` is the version the editor loaded, so a sync that changed the note
    /// underneath it can't be overwritten by the older text in the editor.
    public func saveNote(_ id: UUID, title: String, body: String, basedOn: Date) throws -> NoteSave {
        if let current = try? item(id), current.updatedAt == basedOn {
            return .saved(try saveNote(id, title: title, body: body))
        }
        let copy = try createNote(title: "\(title.isEmpty ? "Untitled" : title) (conflict copy)")
        return .keptAsCopy(try saveNote(copy.id, title: copy.title, body: body))
    }

    public func importFile(_ data: Data, filename: String, collection: String? = nil) throws -> ReaderItem {
        guard data.count <= Self.maxImportBytes else { throw ReaderError.tooLarge }
        let now = Date()
        let item = ReaderItem(
            id: UUID(), kind: .file, title: (filename as NSString).deletingPathExtension,
            collection: collection, mime: ReadableText.mime(forFilename: filename),
            byteCount: data.count, createdAt: now, updatedAt: now, listenPosition: 0
        )
        try writeBody(data, id: item.id)
        try writeMeta(item)
        return item
    }

    public func body(of id: UUID) throws -> Data {
        guard let sealed = try store.read(bodyName(id)) else { throw ReaderError.notFound }
        return try ContentCipher.open(sealed, key: rootKey.objectKey(for: id, purpose: .content), objectID: id)
    }

    /// Plaintext stays in memory. It is never written outside the sealed blobs.
    public func text(of id: UUID) throws -> String {
        if let cached = textCache[id] { return cached }
        let text = try ReadableText.extract(body(of: id), mime: item(id).mime)
        textCache[id] = text
        return text
    }

    /// Listening is not editing, so `updatedAt` stays put.
    public func setListenPosition(_ offset: Int, of id: UUID) throws {
        var updated = try item(id)
        updated.listenPosition = max(0, offset)
        try writeMeta(updated)
    }

    public func delete(_ id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
        // The record goes first, so a crash can't lose the fact that this was deleted on purpose.
        try store.write(Data(), as: deletionName(id))
        try removeBlobs(id)
    }

    private func removeBlobs(_ id: UUID) throws {
        try store.delete(metaName(id))
        try store.delete(bodyName(id))
        textCache[id] = nil
        hashes[id] = nil
    }

    /// Every word must appear in the title or text. Files with no readable text match on title only.
    public func search(_ query: String) throws -> [ReaderSearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return try list().items.compactMap { item in
            let text = (try? text(of: item.id)) ?? ""
            let found = terms.allSatisfy {
                item.title.range(of: $0, options: options) != nil || text.range(of: $0, options: options) != nil
            }
            guard found else { return nil }
            let first = terms.lazy.compactMap { text.range(of: $0, options: options) }.first
            return ReaderSearchHit(item: item, snippet: first.map { snippet(of: text, around: $0) })
        }
    }

    private func snippet(of text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -Self.snippetRadius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: Self.snippetRadius, limitedBy: text.endIndex) ?? text.endIndex
        let excerpt = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + excerpt + (end < text.endIndex ? "…" : "")
    }

    /// Never wraps a key derived from the root: a grantee who kept it could read every later edit
    /// and forge a body the owner would accept.
    public func share(_ id: UUID, with recipient: IdentityBundle) throws -> ReaderShare {
        let item = try item(id)
        let key = try ObjectKey.generate()
        let header = ReaderShare.Header(kind: item.kind, title: item.title, mime: item.mime)
        return ReaderShare(
            objectID: id,
            wrappedKey: try key.wrapped(for: recipient),
            sealedHeader: try ContentCipher.seal(JSONEncoder().encode(header), key: key, objectID: id),
            sealedBody: try ContentCipher.seal(body(of: id), key: key, objectID: id)
        )
    }
}

extension ReaderVault: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.note, .file] }

    public func sealedObjectIDs() throws -> [UUID] {
        // A crash can stop a delete halfway. The record says what was meant, so finish it.
        if !isClosed {
            for id in try deletedObjectIDs() where try store.read(metaName(id)) != nil { try removeBlobs(id) }
        }
        return try store.names().compactMap { name in
            name.hasSuffix(".meta") ? UUID(uuidString: String(name.dropLast(".meta".count))) : nil
        }
    }

    public func sealedHash(of id: UUID) throws -> String? {
        if let known = hashes[id] { return known }
        guard try store.read(bodyName(id)) != nil else { return nil }
        let hash = try sealedObject(id)?.hash
        hashes[id] = hash
        return hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        guard let meta = try store.read(metaName(id)) else { return nil }
        let kind: ContentKind = ((try? item(id).kind) ?? .note) == .note ? .note : .file
        return SealedObject(id: id, kind: kind, meta: meta, body: try store.read(bodyName(id)))
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        guard object.body != nil else { throw CryptoError.malformedCiphertext }
        _ = try opened(object)
        return object
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        if expected == nil, try store.read(deletionName(object.id)) != nil { throw SyncError.changedLocally }
        guard let body = object.body else { throw CryptoError.malformedCiphertext }
        guard try opened(object).item.id == object.id else { throw CryptoError.authenticationFailed }
        try store.write(body, as: bodyName(object.id))
        try store.write(object.meta, as: metaName(object.id))
        textCache[object.id] = nil
        hashes[object.id] = nil
    }

    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard try sealedHash(of: id) == expected else { throw SyncError.changedLocally }
        guard let object = try sealedObject(id) else { return }
        // The stamp goes first, so a crash can't leave trash that's never cleaned up.
        try store.write(Data(ISO8601DateFormatter().string(from: Date()).utf8), as: trashStampName(id))
        try store.write(object.meta, as: metaName(id) + ".trash")
        if let body = object.body { try store.write(body, as: bodyName(id) + ".trash") }
        try removeBlobs(id)
    }

    public func emptyOldTrash() throws {
        guard !isClosed else { return }
        let formatter = ISO8601DateFormatter()
        for name in try store.names() where name.hasSuffix(".trashed") {
            guard let id = UUID(uuidString: String(name.dropLast(".trashed".count))),
                  let stamp = try store.read(name), let date = formatter.date(from: String(decoding: stamp, as: UTF8.self)),
                  Date().timeIntervalSince(date) > Self.trashLifetime
            else { continue }
            try store.delete(metaName(id) + ".trash")
            try store.delete(bodyName(id) + ".trash")
            try store.delete(name)
        }
    }

    private func trashStampName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).trashed" }

    public func deletedObjectIDs() throws -> Set<UUID> {
        Set(try store.names().compactMap { name in
            name.hasSuffix(".deleted") ? UUID(uuidString: String(name.dropLast(".deleted".count))) : nil
        })
    }

    public func clearDeletion(_ id: UUID) throws {
        try store.delete(deletionName(id))
    }

    /// The newest version stays. An older version that differs in any way a person would notice is
    /// kept as a copy. If only a Listen position differs, there's nothing to keep.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        let mine = try opened(local)
        let theirs = try opened(remote)
        let keepMine = mine.item.updatedAt >= theirs.item.updatedAt
        let same = mine.body == theirs.body && mine.item.title == theirs.item.title
            && mine.item.collection == theirs.item.collection
        if !same {
            let older = keepMine ? theirs : mine
            // Named for the version it preserves, so retries can't double it even if this device changes again.
            try writeConflictCopy(of: older.item, body: older.body, id: UUID(derivedFrom: (keepMine ? remote : local).hash))
        }
        return keepMine ? .keepLocal : .keepRemote
    }

    private func opened(_ object: SealedObject) throws -> (item: ReaderItem, body: Data) {
        let id = object.id
        let meta = try ContentCipher.open(object.meta, key: rootKey.objectKey(for: id, purpose: .metadata), objectID: id)
        let body = try object.body.map { try ContentCipher.open($0, key: rootKey.objectKey(for: id, purpose: .content), objectID: id) }
        return (try JSONDecoder().decode(ReaderItem.self, from: meta), body ?? Data())
    }

    private func writeConflictCopy(of item: ReaderItem, body: Data, id: UUID) throws {
        guard try store.read(metaName(id)) == nil else { return }
        let now = Date()
        let copy = ReaderItem(
            id: id, kind: item.kind, title: "\(item.displayTitle) (conflict copy)", collection: item.collection,
            mime: item.mime, byteCount: item.byteCount, createdAt: now, updatedAt: now, listenPosition: 0
        )
        try writeBody(body, id: copy.id)
        try writeMeta(copy)
    }
}
