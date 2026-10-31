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

/// A user's Reader content. Each item is two blobs: metadata and body, under separate per-object
/// keys. Blob names hold only the object ID.
public actor ReaderVault {
    public static let maxImportBytes = 50 * 1024 * 1024
    /// How each kind of blob is sealed, so a key change can reach them without knowing what they are.
    public static let sealedPurposes: [String: KeyPurpose] = [".meta": .metadata, ".body": .content]
    private static let snippetRadius = 60

    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private var textCache: [UUID: String] = [:]
    private var isClosed = false

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        self.rootKey = rootKey
    }

    private func metaName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).meta" }
    private func bodyName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).body" }

    /// Refuses all further writes. A key move lists every blob once, so anything written after that,
    /// sealed under the old key, would be lost when the old key goes.
    public func close() {
        isClosed = true
    }

    private func writeMeta(_ item: ReaderItem) throws {
        guard !isClosed else { throw ReaderError.closed }
        let key = rootKey.objectKey(for: item.id, purpose: .metadata)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(item), key: key, objectID: item.id), as: metaName(item.id))
    }

    private func writeBody(_ data: Data, id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
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
        try store.delete(metaName(id))
        try store.delete(bodyName(id))
        textCache[id] = nil
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
