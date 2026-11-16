import Foundation
import TotalityCore

public struct ReaderListing: Sendable, Equatable {
    public let items: [ReaderItem]
    public let folders: [ReaderItem]
    /// When this device last opened each item or folder.
    public let opened: [UUID: Date]
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

/// Something in Recently Deleted.
public struct TrashedItem: Sendable, Equatable, Identifiable {
    public let item: ReaderItem
    public let deletedAt: Date

    public var id: UUID { item.id }
}

/// How a save from an open note went.
public enum NoteSave: Sendable, Equatable {
    case saved(ReaderItem)
    /// The note changed somewhere else first, so what was typed became a copy and nothing was lost.
    case keptAsCopy(ReaderItem)
}

/// A user's Reader content. Each item is two blobs: metadata and body, under separate per-object
/// keys. Blob names hold only the object ID. A file imported since issue 124 has its body sealed in
/// 4 MB pieces, `<id>.pieces`, so it opens a piece at a time and is never held whole. An older one has a
/// single sealed body, `<id>.body`, and opens as it always did. Docs and folders keep a single body.
public actor ReaderVault {
    /// The sealed store takes up to 5 GB in one blob, and sealing adds a little to each piece.
    public static let maxFileBytes = SealedStoreClient.maxBlob - 1024 * 1024
    /// The most text a doc, or one file's words, may be. Far more than any book.
    public static let maxTextBytes = 64 * 1024 * 1024
    /// How much of a file each sealed piece holds.
    public static let pieceSize = 4 * 1024 * 1024
    /// Files sealed in pieces, which a key change moves a piece at a time.
    public static let chunkedPurposes: [String: KeyPurpose] = [".pieces": .readerPieces, ".pieces.trash": .readerPieces]
    /// How each kind of blob is sealed, so a key change can reach them without knowing what they are.
    public static let sealedPurposes: [String: KeyPurpose] = [
        ".meta": .metadata, ".body": .content, ".meta.trash": .metadata, ".body.trash": .content,
        ".opened": .metadata, ".versions": .docVersion, ".version": .docVersion,
        ReadingPlaceBook.syncedSuffix: .readerPlaces, ReadingPlaceBook.heldSuffix: .readerPlaces,
    ]
    /// How long anything deleted, here or on another device, stays recoverable.
    public static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let store: any BlobStore
    /// The same store, when its blobs are real files, which pieces need. Tests that keep blobs in memory
    /// get single-piece bodies.
    private let files: FileBlobStore?
    private let rootKey: ContentRootKey
    private var textCache: [UUID: String] = [:]
    private var isClosed = false
    private var hashes: [UUID: String] = [:]
    /// Each piece file's size, change time and digest, so a 1 GB file isn't read again on every sync.
    private var digests: [UUID: (size: Int, changed: Date, file: SealedFile)] = [:]
    /// Files opened from outside the vault, like Google Drive (issue 102). In memory only: they're never
    /// written here, listed, searched, or synced, but the viewers and Listen read them like any item.
    private var held: [UUID: (item: ReaderItem, file: ReaderFile)] = [:]
    private var heldOrder: [UUID] = []
    /// A few, so Listen can keep going on one while another is opened.
    static let mostHeld = 3

    public init(store: any BlobStore, rootKey: ContentRootKey) {
        self.store = store
        files = store as? FileBlobStore
        self.rootKey = rootKey
    }

    private func metaName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).meta" }
    private nonisolated func piecesName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).pieces" }
    private nonisolated func importingName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).pieces-importing" }
    private func incomingName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).pieces-incoming" }
    private nonisolated func piecesKey(_ id: UUID) -> ObjectKey { rootKey.objectKey(for: id, purpose: .readerPieces) }

    private func hasPieces(_ id: UUID) throws -> Bool {
        guard let files else { return false }
        return try files.exists(piecesName(id))
    }

    private func piecesReader(_ url: URL, id: UUID, keep: Int = ReaderFile.piecesKept) throws -> ChunkedCipher.Reader {
        try ChunkedCipher.Reader(file: url, key: piecesKey(id), objectID: id, keepChunks: keep)
    }
    private func deletionName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).deleted" }
    private func bodyName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).body" }
    private func openedName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).opened" }

    /// Refuses all further writes. A key move lists every blob once, so anything written after that,
    /// sealed under the old key, would be lost when the old key goes.
    public func close() {
        isClosed = true
        releaseHeld()
    }

    private func writeMeta(_ item: ReaderItem) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard held[item.id] == nil else { throw ReaderError.notFound }
        hashes[item.id] = nil
        let key = rootKey.objectKey(for: item.id, purpose: .metadata)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(item), key: key, objectID: item.id), as: metaName(item.id))
    }

    private func writeBody(_ data: Data, id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard held[id] == nil else { throw ReaderError.notFound }
        hashes[id] = nil
        let key = rootKey.objectKey(for: id, purpose: .content)
        try store.write(try ContentCipher.seal(data, key: key, objectID: id), as: bodyName(id))
        // One body per item, so a file that was sealed in pieces is now this.
        try store.delete(piecesName(id))
        digests[id] = nil
        textCache[id] = nil
    }

    /// Puts a finished piece file in place as an item's body.
    private func placePieces(_ url: URL, id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard held[id] == nil, let files else { throw ReaderError.notFound }
        let target = try files.location(of: piecesName(id))
        if url.standardizedFileURL != target.standardizedFileURL {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: url)
            } else {
                try FileManager.default.moveItem(at: url, to: target)
            }
        }
        try store.delete(bodyName(id))
        hashes[id] = nil
        digests[id] = nil
        textCache[id] = nil
    }

    /// Seals `data` as an item's body in pieces when this store can hold them, or whole when it can't.
    private func writeFileBody(_ data: Data, id: UUID) throws {
        guard let files, !data.isEmpty else { return try writeBody(data, id: id) }
        let part = try files.location(of: importingName(id))
        do {
            try ReaderFile(data: data).reseal(to: part, key: piecesKey(id), objectID: id)
            try placePieces(part, id: id)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    public func item(_ id: UUID) throws -> ReaderItem {
        if let outside = held[id] { return outside.item }
        guard let sealed = try store.read(metaName(id)) else { throw ReaderError.notFound }
        let key = rootKey.objectKey(for: id, purpose: .metadata)
        return try JSONDecoder().decode(ReaderItem.self, from: ContentCipher.open(sealed, key: key, objectID: id))
    }

    public func list() throws -> ReaderListing {
        let (all, unreadable) = try everything()
        // The journal has a page of its own and never mixes with the library.
        let sorted = all.filter { $0.kind != .journal }.sorted { $0.updatedAt > $1.updatedAt }
        return ReaderListing(
            items: sorted.filter { $0.kind != .folder }, folders: sorted.filter { $0.kind == .folder },
            opened: try openedDates(), unreadable: unreadable
        )
    }

    /// Every item that opens, the journal's too, and how many didn't.
    private func everything() throws -> ([ReaderItem], Int) {
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
        return (items, unreadable)
    }

    /// A time that won't open only costs an item its place in the list.
    private func openedDates() throws -> [UUID: Date] {
        var dates: [UUID: Date] = [:]
        for name in try store.names() where name.hasSuffix(".opened") {
            guard let id = UUID(uuidString: String(name.dropLast(".opened".count))), let sealed = try store.read(name) else { continue }
            let key = rootKey.objectKey(for: id, purpose: .metadata)
            dates[id] = try? JSONDecoder().decode(Date.self, from: ContentCipher.open(sealed, key: key, objectID: id))
        }
        return dates
    }

    private func library() throws -> ReaderLibrary {
        let listing = try list()
        return ReaderLibrary(items: listing.items, folders: listing.folders)
    }

    public func createFolder(title: String, in parent: UUID? = nil) throws -> ReaderItem {
        try writeFolder(id: UUID(), title: title, in: parent)
    }

    private func writeFolder(id: UUID, title: String, in parent: UUID?) throws -> ReaderItem {
        let now = Date()
        let folder = ReaderItem(
            id: id, kind: .folder, title: title, collection: nil, mime: nil,
            byteCount: 0, createdAt: now, updatedAt: now, listenPosition: 0, folderID: parent
        )
        try writeBody(Data(), id: id)
        try writeMeta(folder)
        return folder
    }

    /// The ID comes from the name and the key, so two of this person's devices land on one folder,
    /// and the server can't spot a folder name by its ID.
    public func namedFolder(_ name: String) throws -> ReaderItem {
        let id = rootKey.derivedID(from: "reader-folder:\(name)")
        if let existing = try? item(id) { return existing }
        try store.delete(deletionName(id))
        return try writeFolder(id: id, title: name, in: nil)
    }

    /// Collections were plain labels. Each becomes a real folder. The time stays as it was, because
    /// tidying up isn't an edit.
    public func adoptCollections() throws {
        guard !isClosed else { return }
        for var item in try list().items {
            guard let collection = item.collection else { continue }
            item.folderID = try namedFolder(collection).id
            item.collection = nil
            try writeMeta(item)
        }
    }

    public func rename(_ id: UUID, to title: String) throws {
        var updated = try item(id)
        guard updated.kind != .journal else { throw ReaderError.journalIsPrivate }
        updated.title = title
        updated.updatedAt = Date()
        try writeMeta(updated)
    }

    /// Where something lives isn't an edit, so this leaves the time alone, and an open doc on another
    /// device isn't told it fell behind.
    public func move(_ id: UUID, to folder: UUID?) throws {
        var updated = try item(id)
        guard updated.kind != .journal else { throw ReaderError.journalIsPrivate }
        guard try library().canMove(updated, to: folder) else { throw ReaderError.folderInsideItself }
        updated.folderID = folder
        try writeMeta(updated)
    }

    public func createNote(title: String = "", folder: UUID? = nil) throws -> ReaderItem {
        let now = Date()
        let item = ReaderItem(
            id: UUID(), kind: .note, title: title, collection: nil, mime: MarkdownText.mime,
            byteCount: 0, createdAt: now, updatedAt: now, listenPosition: 0, folderID: folder
        )
        try writeBody(Data(), id: item.id)
        try writeMeta(item)
        return item
    }

    /// Reads the latest metadata first, so saving a note never undoes a newer Listen position.
    @discardableResult
    public func saveNote(_ id: UUID, title: String, body: String, mime: String? = nil) throws -> ReaderItem {
        var updated = try item(id)
        guard updated.kind == .note else { throw ReaderError.notANote }
        let data = Data(body.utf8)
        updated.title = title
        if let mime { updated.mime = mime }
        updated.byteCount = data.count
        updated.updatedAt = Date()
        try writeBody(data, id: id)
        try writeMeta(updated)
        return updated
    }

    /// For an open note. `basedOn` is the version the editor loaded, so a sync that changed the note
    /// underneath it can't be overwritten by the older text in the editor.
    public func saveNote(_ id: UUID, title: String, body: String, mime: String? = nil, basedOn: Date) throws -> NoteSave {
        if let current = try? item(id), current.updatedAt == basedOn {
            return .saved(try saveNote(id, title: title, body: body, mime: mime))
        }
        let copy = try createNote(title: "\(title.isEmpty ? "Untitled" : title) (conflict copy)", folder: try? item(id).folderID)
        return .keptAsCopy(try saveNote(copy.id, title: copy.title, body: body, mime: mime))
    }

    /// A note's text for the writing editor. A doc from before the editor is converted to Markdown first,
    /// once, and its old self is kept beside it as a read-only file until the person confirms.
    public func markdown(of id: UUID) throws -> (item: ReaderItem, text: String) {
        var current = try item(id)
        guard current.kind == .note else { throw ReaderError.notANote }
        let data = try body(of: id)
        let old = String(decoding: data, as: UTF8.self)
        if current.mime == MarkdownText.mime { return (current, old) }
        let doc = current.mime == ReadableText.markdownMime ? DocText(markdown: old) : DocText(plain: old)
        let converted = MarkdownText.markdown(from: doc)
        if !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.keptOriginalID = try keepOriginal(of: current, body: data).id
        }
        // Tidying up isn't an edit, so the time stays. Two devices converting the same doc write the same
        // words under the same time, and sync sees nothing to keep a copy of.
        current.mime = MarkdownText.mime
        current.byteCount = converted.utf8.count
        try writeBody(Data(converted.utf8), id: id)
        try writeMeta(current)
        return (current, converted)
    }

    /// The ID comes from the doc's, so a second conversion on another device lands on the same copy.
    private func keepOriginal(of note: ReaderItem, body: Data) throws -> ReaderItem {
        let id = rootKey.derivedID(from: "reader-original:\(note.id.uuidString.lowercased())")
        try store.delete(deletionName(id))
        let now = Date()
        let original = ReaderItem(
            id: id, kind: .file, title: "\(note.displayTitle) (before the new editor)", collection: nil,
            mime: note.mime == ReadableText.markdownMime ? ReadableText.markdownMime : "text/plain",
            byteCount: body.count, createdAt: now, updatedAt: now, listenPosition: 0, folderID: note.folderID
        )
        try writeBody(body, id: id)
        try writeMeta(original)
        return original
    }

    /// Setting a target isn't an edit, so the date stays and an open doc elsewhere isn't told it fell behind.
    public func setWordTarget(_ target: Int?, of id: UUID) throws {
        var current = try item(id)
        guard current.kind == .note else { throw ReaderError.notANote }
        current.wordTarget = target.flatMap { $0 > 0 ? min($0, 10_000_000) : nil }
        try writeMeta(current)
    }

    /// The person says the converted doc looks right, so its old self goes to Recently Deleted, where it
    /// can still be brought back for a while.
    public func confirmConversion(_ id: UUID) throws {
        var current = try item(id)
        guard let original = current.keptOriginalID else { return }
        if (try? item(original)) != nil { try delete(original) }
        current.keptOriginalID = nil
        try writeMeta(current)
    }

    /// Imports a file the person chose on this device. It's read and sealed a piece at a time, away from
    /// the vault, so even a big file never sits in memory whole and the library stays usable meanwhile.
    /// `progress` hears how far it's got, from 0 to 1.
    public nonisolated func importFile(
        at url: URL, filename: String, folder: UUID? = nil, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ReaderItem {
        let source = try PlainFileSource(url)
        let count = source.count
        guard count <= Self.maxFileBytes else { throw ReaderError.tooLarge }
        // A reference library is read whole to become CSL JSON, and an empty file has no pieces.
        guard let files, count > 0, !References.mightBeLibrary(filename) else {
            guard count <= ReaderFile.wholeLimit else { throw ReaderError.tooLarge }
            return try await importFile(try source.read(0..<count), filename: filename, folder: folder)
        }
        try Self.checkRoom(for: ChunkedCipher.sealedLength(plain: count, chunkSize: Self.pieceSize), near: try files.location(of: "room"))
        let id = UUID()
        let part = try files.location(of: importingName(id))
        do {
            try ChunkedCipher.seal(file: url, to: part, key: piecesKey(id), objectID: id, chunkSize: Self.pieceSize) { done in
                progress?(Double(done) / Double(count))
            }
            let mime = ReadableText.mime(forFilename: filename)
            // A book's own title beats its filename. One that can't be read still gets stored.
            let bookTitle = mime == ReadableText.epubMime ? (try? BookReader.epubTitle(source)) ?? nil : nil
            return try await finishImport(part, id: id, filename: filename, title: bookTitle, mime: mime, count: count, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    private func finishImport(
        _ part: URL, id: UUID, filename: String, title: String?, mime: String?, count: Int, folder: UUID?
    ) throws -> ReaderItem {
        let now = Date()
        let item = ReaderItem(
            id: id, kind: .file, title: title ?? (filename as NSString).deletingPathExtension,
            collection: nil, mime: mime,
            byteCount: count, createdAt: now, updatedAt: now, listenPosition: 0, folderID: folder
        )
        try placePieces(part, id: id)
        try writeMeta(item)
        return item
    }

    /// Refuses a file this device hasn't room to keep sealed, with room to spare for everything else.
    static func checkRoom(for bytes: Int, near url: URL) throws {
        let folder = url.deletingLastPathComponent()
        guard let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        else { return }
        // A free volume of zero means it couldn't be measured, as happens on some Macs.
        guard free == 0 || Int64(bytes) + 200 * 1024 * 1024 <= free else { throw ReaderError.noRoomHere }
    }

    /// A file opened a piece at a time somewhere else, like a big file from Drive, sealed again here a
    /// piece at a time under its own key.
    public func importFile(_ source: ReaderFile, filename: String, folder: UUID? = nil) throws -> ReaderItem {
        guard source.isPieces, let files else { return try importFile(try source.whole(), filename: filename, folder: folder) }
        guard source.count <= Self.maxFileBytes else { throw ReaderError.tooLarge }
        try Self.checkRoom(for: ChunkedCipher.sealedLength(plain: source.count, chunkSize: Self.pieceSize), near: try files.location(of: "room"))
        let id = UUID()
        let part = try files.location(of: importingName(id))
        do {
            try source.reseal(to: part, key: piecesKey(id), objectID: id)
            let mime = ReadableText.mime(forFilename: filename)
            let title = mime == ReadableText.epubMime ? (try? BookReader.epubTitle(source)) ?? nil : nil
            return try finishImport(part, id: id, filename: filename, title: title, mime: mime, count: source.count, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    public func importFile(_ data: Data, filename: String, folder: UUID? = nil) throws -> ReaderItem {
        guard data.count <= Self.maxFileBytes else { throw ReaderError.tooLarge }
        // A .bib or CSL JSON file becomes a reference library, stored as CSL JSON whatever it came as.
        if let library = References.library(from: data, filename: filename) {
            return try importLibrary(library, title: (filename as NSString).deletingPathExtension, folder: folder)
        }
        let now = Date()
        let mime = ReadableText.mime(forFilename: filename)
        // A book's own title beats its filename. One that can't be read still gets stored.
        let bookTitle = mime == ReadableText.epubMime ? (try? BookReader.epubTitle(data)) ?? nil : nil
        let item = ReaderItem(
            id: UUID(), kind: .file, title: bookTitle ?? (filename as NSString).deletingPathExtension,
            collection: nil, mime: mime,
            byteCount: data.count, createdAt: now, updatedAt: now, listenPosition: 0, folderID: folder
        )
        try writeFileBody(data, id: item.id)
        try writeMeta(item)
        return item
    }

    private func importLibrary(_ library: Data, title: String, folder: UUID?) throws -> ReaderItem {
        let now = Date()
        let item = ReaderItem(
            id: UUID(), kind: .file, title: title, collection: nil, mime: References.mime,
            byteCount: library.count, createdAt: now, updatedAt: now, listenPosition: 0, folderID: folder
        )
        try writeBody(library, id: item.id)
        try writeMeta(item)
        return item
    }

    /// Every reference library's items as one CSL JSON array, for citing. When two libraries share a
    /// key, the newer library wins, so re-importing an updated export takes effect.
    public func referenceLibrary() throws -> Data {
        var seen = Set<String>()
        var merged: [[String: Any]] = []
        for item in try list().items where item.mime == References.mime {
            guard let body = try? body(of: item.id), let items = References.cslItems(body) else { continue }
            for entry in items {
                guard let id = entry["id"] as? String, seen.insert(id).inserted, merged.count < References.maxItems else { continue }
                merged.append(entry)
            }
        }
        return try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }

    /// The item's body, whole. For a file sealed in pieces this is refused past `ReaderFile.wholeLimit`:
    /// those are read through `file(of:)` instead.
    public func body(of id: UUID) throws -> Data {
        try file(of: id).whole()
    }

    /// The item's bytes, ready to read a range at a time. Pieces are unsealed only as they're read.
    public func file(of id: UUID) throws -> ReaderFile {
        if let outside = held[id] { return outside.file }
        if let files, try hasPieces(id) { return ReaderFile(pieces: try piecesReader(try files.location(of: piecesName(id)), id: id)) }
        guard let sealed = try store.read(bodyName(id)) else { throw ReaderError.notFound }
        return ReaderFile(data: try ContentCipher.open(sealed, key: rootKey.objectKey(for: id, purpose: .content), objectID: id))
    }

    /// Plaintext stays in memory. It is never written outside the sealed blobs. A PDF or a book is read
    /// a page or a part at a time to get it.
    public func text(of id: UUID) throws -> String {
        if let cached = textCache[id] { return cached }
        let text = try ReadableText.extract(file(of: id), mime: item(id).mime)
        textCache[id] = text
        return text
    }

    public func document(of id: UUID) throws -> ReadableDocument {
        try ReadableText.document(file(of: id), mime: item(id).mime)
    }

    /// Kept in its own file on this device. In the sealed details it would re-upload the item's whole
    /// body on every open, and show the server when someone reads. Sync never sees this file.
    public func markOpened(_ id: UUID, at date: Date) throws {
        guard !isClosed else { throw ReaderError.closed }
        // Anything left behind would make an empty device look like it has content.
        guard try store.read(metaName(id)) != nil else { throw ReaderError.notFound }
        let key = rootKey.objectKey(for: id, purpose: .metadata)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(date), key: key, objectID: id), as: openedName(id))
    }

    /// Listening is not editing, so `updatedAt` stays put.
    public func setListenPosition(_ offset: Int, of id: UUID) throws {
        if held[id] != nil {
            held[id]?.item.listenPosition = max(0, offset)
            return
        }
        var updated = try item(id)
        updated.listenPosition = max(0, offset)
        try writeMeta(updated)
    }

    /// Moves it to Recently Deleted, along with anything inside it. Returns every ID that went.
    @discardableResult
    public func delete(_ id: UUID) throws -> [UUID] {
        guard !isClosed else { throw ReaderError.closed }
        guard held[id] == nil else { throw ReaderError.notFound }
        let inside = (try? item(id).kind) == .folder ? try library().descendants(of: id).map(\.id) : []
        for target in inside + [id] {
            // The record goes first, so a crash can't lose the fact that this was deleted on purpose.
            try store.write(Data(), as: deletionName(target))
            try moveToTrash(target)
        }
        return inside + [id]
    }

    private func moveToTrash(_ id: UUID) throws {
        guard let meta = try store.read(metaName(id)) else { return }
        // The stamp goes first, so a crash can't leave trash that's never cleaned up.
        try store.write(Data(ISO8601DateFormatter().string(from: Date()).utf8), as: trashStampName(id))
        try store.write(meta, as: metaName(id) + ".trash")
        if let files, try hasPieces(id) {
            // Moved, not copied, so a big file never needs room twice.
            let trash = try files.location(of: piecesName(id) + ".trash")
            try? FileManager.default.removeItem(at: trash)
            try FileManager.default.moveItem(at: try files.location(of: piecesName(id)), to: trash)
        } else if let body = try store.read(bodyName(id)) {
            try store.write(body, as: bodyName(id) + ".trash")
        }
        try removeBlobs(id)
    }

    private func removeTrash(_ id: UUID) throws {
        try store.delete(metaName(id) + ".trash")
        try store.delete(bodyName(id) + ".trash")
        try store.delete(piecesName(id) + ".trash")
        try store.delete(trashStampName(id))
    }

    /// Everything in the trash that opens, including what's inside trashed folders.
    private func allTrash() throws -> [TrashedItem] {
        let formatter = ISO8601DateFormatter()
        return try store.names().compactMap { name -> TrashedItem? in
            guard name.hasSuffix(".trashed"), let id = UUID(uuidString: String(name.dropLast(".trashed".count))),
                  let stamp = try store.read(name), let meta = try store.read(metaName(id) + ".trash"),
                  let item = try? openedItem(meta, id: id)
            else { return nil }
            let date = formatter.date(from: String(decoding: stamp, as: UTF8.self)) ?? Date()
            return TrashedItem(item: item, deletedAt: date)
        }
    }

    /// Recently Deleted, newest first. What's inside a trashed folder comes and goes with it.
    public func trashed() throws -> [TrashedItem] {
        let trash = try allTrash()
        // The same rule as the library, so a looped folder shows here instead of vanishing with its contents.
        let tree = ReaderLibrary(folders: trash.map(\.item).filter { $0.kind == .folder })
        return trash
            .filter { tree.parent(of: $0.item) == nil }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    private func trashedTree(_ id: UUID) throws -> [UUID] {
        let children = Dictionary(grouping: try allTrash().map(\.item), by: \.folderID)
        var tree = [id]
        var seen: Set = [id]
        var index = 0
        while index < tree.count {
            for child in children[tree[index]] ?? [] where seen.insert(child.id).inserted { tree.append(child.id) }
            index += 1
        }
        return tree
    }

    public func restore(_ id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
        for target in try trashedTree(id) { try restoreOne(target) }
    }

    private func restoreOne(_ id: UUID) throws {
        guard let meta = try store.read(metaName(id) + ".trash") else { throw ReaderError.notFound }
        let trashedPieces = try files.flatMap { files -> URL? in
            let url = try files.location(of: piecesName(id) + ".trash")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let body = trashedPieces == nil ? try store.read(bodyName(id) + ".trash") : nil
        if try store.read(metaName(id)) != nil {
            // It came back another way, so this version stays beside it rather than replacing it.
            let item = try openedItem(meta, id: id)
            if item.kind != .folder {
                let file = try trashedPieces.map { ReaderFile(pieces: try piecesReader($0, id: id, keep: 0)) }
                    ?? ReaderFile(data: try body.map { try ContentCipher.open($0, key: rootKey.objectKey(for: id, purpose: .content), objectID: id) } ?? Data())
                try writeConflictCopy(of: item, file: file, id: UUID())
            }
        } else {
            if let trashedPieces {
                try placePieces(trashedPieces, id: id)
            } else if let body {
                try store.write(body, as: bodyName(id))
            }
            try store.write(meta, as: metaName(id))
            try store.delete(deletionName(id))
            hashes[id] = nil
        }
        try removeTrash(id)
    }

    /// For when the person chooses this. It can't be undone.
    public func deleteForever(_ id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
        for target in try trashedTree(id) {
            try removeTrash(target)
            try removeVersions(of: target)
        }
    }

    public func emptyTrash() throws {
        guard !isClosed else { throw ReaderError.closed }
        for entry in try allTrash() {
            try removeTrash(entry.id)
            try removeVersions(of: entry.id)
        }
    }

    private func removeBlobs(_ id: UUID) throws {
        try store.delete(metaName(id))
        try store.delete(bodyName(id))
        try store.delete(piecesName(id))
        try store.delete(openedName(id))
        textCache[id] = nil
        hashes[id] = nil
        digests[id] = nil
    }

    /// Every word must appear in the title or text. Files with no readable text match on title only.
    public func search(_ query: String) throws -> [ReaderSearchHit] {
        let terms = SearchText.terms(in: query)
        guard !terms.isEmpty else { return [] }
        // The journal is searched too, though it's listed apart.
        let journal = try everything().0.filter { $0.kind == .journal }.sorted { $0.updatedAt > $1.updatedAt }
        return try (try list().items + journal).compactMap { item in
            // A newer search is waiting on this actor, so a stale one stops between items.
            try Task.checkCancellation()
            let text = (try? text(of: item.id)) ?? ""
            let found = terms.allSatisfy { SearchText.find($0, in: item.title) != nil || SearchText.find($0, in: text) != nil }
            guard found else { return nil }
            let first = terms.lazy.compactMap { SearchText.find($0, in: text) }.first
            return ReaderSearchHit(item: item, snippet: first.map { SearchText.excerpt(of: text, around: $0) })
        }
    }

    /// Never wraps a key derived from the root: a grantee who kept it could read every later edit
    /// and forge a body the owner would accept.
    /// A share is one sealed snapshot, so a file has to fit in memory to be shared this way.
    public func share(_ id: UUID, with recipient: IdentityBundle) throws -> ReaderShare {
        let item = try item(id)
        guard item.kind != .journal else { throw ReaderError.journalIsPrivate }
        let body = try file(of: id).whole()
        let key = try ObjectKey.generate()
        let header = ReaderShare.Header(kind: item.kind, title: item.title, mime: item.mime)
        return ReaderShare(
            objectID: id,
            wrappedKey: try key.wrapped(for: recipient),
            sealedHeader: try ContentCipher.seal(JSONEncoder().encode(header), key: key, objectID: id),
            sealedBody: try ContentCipher.seal(body, key: key, objectID: id)
        )
    }
}

extension ReaderVault: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.note, .file] }

    public func sealedObjectIDs() throws -> [UUID] {
        // A crash can stop a delete halfway. The record says what was meant, so finish it.
        if !isClosed {
            for id in try deletedObjectIDs() where try store.read(metaName(id)) != nil { try moveToTrash(id) }
            clearLeftovers()
        }
        return try store.names().compactMap { name in
            name.hasSuffix(".meta") ? UUID(uuidString: String(name.dropLast(".meta".count))) : nil
        }
    }

    public func sealedHash(of id: UUID) throws -> String? {
        if let known = hashes[id] { return known }
        guard try hasPieces(id) || store.exists(bodyName(id)) else { return nil }
        let hash = try sealedObject(id)?.hash
        hashes[id] = hash
        return hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        guard let meta = try store.read(metaName(id)) else { return nil }
        // A folder travels as a note, so the server can't tell how someone organizes things.
        let kind: ContentKind = (try? item(id).kind) == .file ? .file : .note
        if let files, try hasPieces(id) {
            return SealedObject(id: id, kind: kind, meta: meta, bodyFile: try pieceFile(try files.location(of: piecesName(id)), id: id))
        }
        return SealedObject(id: id, kind: kind, meta: meta, body: try store.read(bodyName(id)))
    }

    /// A piece file as sync carries it. Its digest is worked out once and kept while the file is unchanged.
    private func pieceFile(_ url: URL, id: UUID) throws -> SealedFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? -1
        let changed = values.contentModificationDate ?? .distantPast
        if let known = digests[id], known.size == size, known.changed == changed, known.file.url == url { return known.file }
        let file = try SealedFile(reading: url)
        digests[id] = (size, changed, file)
        return file
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        guard let object = try sealedObject(id) else { return nil }
        guard object.hasBody else { throw CryptoError.malformedCiphertext }
        _ = try openedItem(object.meta, id: id)
        // Every piece is opened once, so a file damaged anywhere never replaces the server's copy.
        try openedFile(object, keep: 0).verify()
        return object
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard try sealedHash(of: object.id) == expected else { throw SyncError.changedLocally }
        if expected == nil, try store.read(deletionName(object.id)) != nil { throw SyncError.changedLocally }
        let (object, made) = try asFile(object)
        defer { if let made { try? FileManager.default.removeItem(at: made) } }
        guard object.hasBody else { throw CryptoError.malformedCiphertext }
        let theirs = try openedItem(object.meta, id: object.id)
        guard theirs.id == object.id else { throw CryptoError.authenticationFailed }
        // A journal day that's over keeps its words. Leaving this copy as it is means the next sync sends
        // the locked one back, so an older device can't overwrite it.
        if try journalKeepsWords(object, theirs: theirs) {
            // Their words may be newer than the clocks say, so they're kept as a note under the day.
            // Named for the version, so a second sync can't make a second note, and keyed, so the server
            // can't tell the note came from a refused upload.
            let incoming = try openedFile(object, keep: 0)
            if try !file(of: object.id).sameBytes(as: incoming) {
                try writeConflictCopy(of: theirs, file: incoming, id: rootKey.derivedID(from: "reader-journal-kept:\(object.hash)"))
            }
            return
        }
        if let file = object.bodyFile {
            let ours = try files?.location(of: piecesName(object.id))
            // The same pieces already here need no second look. Anything else is opened in full first.
            if file.url.standardizedFileURL != ours?.standardizedFileURL { try openedFile(object, keep: 0).verify() }
            try placePieces(file.url, id: object.id)
        } else if let body = object.body {
            _ = try openedFile(object, keep: 0)
            try store.write(body, as: bodyName(object.id))
            try store.delete(piecesName(object.id))
            digests[object.id] = nil
        }
        try store.write(object.meta, as: metaName(object.id))
        textCache[object.id] = nil
        hashes[object.id] = nil
    }

    /// A body small enough to arrive in memory that was sealed in pieces is put in a file, since pieces
    /// are only ever read from one. Returns the file made, for the caller to clear if it isn't kept.
    private func asFile(_ object: SealedObject) throws -> (SealedObject, URL?) {
        guard let body = object.body, body.first == ChunkedCipher.version else { return (object, nil) }
        guard let files else { throw CryptoError.malformedCiphertext }
        let url = try files.location(of: incomingName(object.id))
        try body.write(to: url, options: .atomic)
        return (SealedObject(id: object.id, kind: object.kind, meta: object.meta, bodyFile: try SealedFile(reading: url)), url)
    }

    /// Imports and downloads cut off by a crash leave part-made files behind. They're ciphertext, but big.
    private func clearLeftovers() {
        guard let files, let names = try? files.names() else { return }
        for name in names where name.hasSuffix(".pieces-incoming") || name.hasSuffix(".pieces-moving") {
            try? files.delete(name)
        }
        // An import still under way is newer than a day.
        for name in names where name.hasSuffix(".pieces-importing") {
            guard let url = try? files.location(of: name),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(date) > 24 * 60 * 60
            else { continue }
            try? files.delete(name)
        }
    }

    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard try sealedHash(of: id) == expected else { throw SyncError.changedLocally }
        try moveToTrash(id)
    }

    public func emptyOldTrash() throws {
        guard !isClosed else { return }
        let formatter = ISO8601DateFormatter()
        for name in try store.names() where name.hasSuffix(".trashed") {
            guard let id = UUID(uuidString: String(name.dropLast(".trashed".count))),
                  let stamp = try store.read(name), let date = formatter.date(from: String(decoding: stamp, as: UTF8.self)),
                  Date().timeIntervalSince(date) > Self.trashLifetime
            else { continue }
            try removeTrash(id)
            try removeVersions(of: id)
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

    /// The newest version stays. An older version with different words or a different name is kept as
    /// a copy. If only a Listen position or a location differs, there's nothing to keep, and a folder
    /// has nothing to keep at all.
    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        let (local, madeLocal) = try asFile(local)
        defer { if let madeLocal { try? FileManager.default.removeItem(at: madeLocal) } }
        let (remote, madeRemote) = try asFile(remote)
        defer { if let madeRemote { try? FileManager.default.removeItem(at: madeRemote) } }
        let mine = try openedItem(local.meta, id: local.id)
        let theirs = try openedItem(remote.meta, id: remote.id)
        var keepMine = mine.updatedAt >= theirs.updatedAt
        if let lock = journalLock(mine) ?? journalLock(theirs) {
            // A day that's over keeps what was written before it ended. The other version becomes a note
            // under that day, so nothing is lost.
            let mineInTime = mine.updatedAt <= lock
            let theirsInTime = theirs.updatedAt <= lock
            if mineInTime != theirsInTime {
                keepMine = mineInTime
            } else if !mineInTime {
                keepMine = mine.updatedAt <= theirs.updatedAt
            }
        }
        let mineFile = try openedFile(local, keep: 0)
        let theirsFile = try openedFile(remote, keep: 0)
        let same = try mine.kind == .folder || (mine.title == theirs.title && mineFile.sameBytes(as: theirsFile))
        if !same {
            // Named for the version it preserves, so retries can't double it even if this device changes again.
            try writeConflictCopy(
                of: keepMine ? theirs : mine, file: keepMine ? theirsFile : mineFile,
                id: UUID(derivedFrom: (keepMine ? remote : local).hash)
            )
        }
        return keepMine ? .keepLocal : .keepRemote
    }

    private func openedItem(_ meta: Data, id: UUID) throws -> ReaderItem {
        let plain = try ContentCipher.open(meta, key: rootKey.objectKey(for: id, purpose: .metadata), objectID: id)
        return try JSONDecoder().decode(ReaderItem.self, from: plain)
    }

    /// The object's body, opened. A body in pieces is checked a piece at a time as it's read.
    private func openedFile(_ object: SealedObject, keep: Int = ReaderFile.piecesKept) throws -> ReaderFile {
        let id = object.id
        if let file = object.bodyFile { return ReaderFile(pieces: try piecesReader(file.url, id: id, keep: keep)) }
        guard let body = object.body else { return ReaderFile(data: Data()) }
        return ReaderFile(data: try ContentCipher.open(body, key: rootKey.objectKey(for: id, purpose: .content), objectID: id))
    }

    private func writeConflictCopy(of item: ReaderItem, file: ReaderFile, id: UUID) throws {
        guard try store.read(metaName(id)) == nil else { return }
        let now = Date()
        let copy = if let stamp = item.journal {
            // A journal copy stays in the journal, as a note under the same day, locked when that day is.
            ReaderItem(
                id: id, kind: .journal, title: "Conflict copy", collection: nil, mime: item.mime,
                byteCount: item.byteCount, createdAt: now, updatedAt: min(now, stamp.locksAt ?? now), listenPosition: 0,
                journal: JournalStamp(day: stamp.day, zone: stamp.zone, about: stamp.about ?? stamp.day, closedAt: stamp.closedAt)
            )
        } else {
            ReaderItem(
                id: id, kind: item.kind, title: "\(item.displayTitle) (conflict copy)", collection: nil,
                mime: item.mime, byteCount: item.byteCount, createdAt: now, updatedAt: now, listenPosition: 0,
                folderID: item.folderID
            )
        }
        if file.isPieces, let files {
            // Sealed again under the copy's own ID and key, a piece at a time.
            let part = try files.location(of: importingName(id))
            do {
                try file.reseal(to: part, key: piecesKey(id), objectID: id)
                try placePieces(part, id: id)
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw error
            }
        } else {
            try writeBody(try file.whole(), id: copy.id)
        }
        try writeMeta(copy)
    }

    // MARK: Links between docs

    /// The docs whose wiki links lead here, newest first. A link leads here when it names this doc's
    /// title and no other doc with that title is a better match for it.
    public func backlinks(to id: UUID) throws -> [WikiLinks.Backlink] {
        let target = try item(id)
        let key = WikiLinks.titleKey(target.title)
        guard target.kind == .note, !key.isEmpty else { return [] }
        let notes = try list().items.filter { $0.kind == .note }
        return try notes.compactMap { source -> WikiLinks.Backlink? in
            try Task.checkCancellation()
            guard source.id != id, source.mime == MarkdownText.mime,
                  let text = try? String(decoding: body(of: source.id), as: UTF8.self), text.contains("[[")
            else { return nil }
            let leadsHere = { (link: WikiLinks.Link) in
                !link.target.isEmpty && WikiLinks.titleKey(link.target) == key
                    && WikiLinks.resolve(link.target, in: notes, near: source.folderID)?.id == id
            }
            let count = WikiLinks.links(in: text).filter(leadsHere).count
            guard count > 0 else { return nil }
            return WikiLinks.Backlink(item: source, snippet: WikiLinks.snippet(text, where: leadsHere), count: count)
        }
        .sorted { $0.item.updatedAt > $1.item.updatedAt }
    }

    // MARK: Versions

    private func versionsName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).versions" }
    private func versionName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).version" }

    /// A doc's earlier versions on this device, newest first.
    public func versions(of id: UUID) throws -> [DocVersion] {
        guard held[id] == nil, let sealed = try store.read(versionsName(id)) else { return [] }
        let key = rootKey.objectKey(for: id, purpose: .docVersion)
        return try JSONDecoder().decode([DocVersion].self, from: ContentCipher.open(sealed, key: key, objectID: id))
    }

    /// Keeps the doc as it's saved now, unless that's what the newest version already holds. Older
    /// versions are thinned as new ones come. A file from outside, like Drive's, has no versions here.
    @discardableResult
    public func snapshot(_ id: UUID, at now: Date = Date()) throws -> DocVersion? {
        guard !isClosed else { throw ReaderError.closed }
        guard held[id] == nil else { return nil }
        let note = try item(id)
        guard note.kind == .note else { throw ReaderError.notANote }
        let data = try body(of: id)
        guard !data.isEmpty else { return nil }
        // A list that won't open is left alone rather than replaced, so nothing in it is lost.
        let existing = try versions(of: id)
        if let latest = existing.first, (try? versionBody(latest.id)) == data { return nil }
        let version = DocVersion(
            id: UUID(), savedAt: now, title: note.title,
            words: DocVersions.words(String(decoding: data, as: UTF8.self)), byteCount: data.count
        )
        // The text goes first, so a crash can't leave the list naming a version that isn't there.
        let key = rootKey.objectKey(for: version.id, purpose: .docVersion)
        try store.write(try ContentCipher.seal(data, key: key, objectID: version.id), as: versionName(version.id))
        let kept = DocVersions.thinned([version] + existing, now: now)
        try writeVersions(kept, of: id)
        let keptIDs = Set(kept.map(\.id))
        for gone in existing where !keptIDs.contains(gone.id) { try store.delete(versionName(gone.id)) }
        return version
    }

    /// One version's text. Only a version on the doc's own list opens.
    public func versionText(_ versionID: UUID, of id: UUID) throws -> String {
        guard try versions(of: id).contains(where: { $0.id == versionID }) else { throw ReaderError.notFound }
        return String(decoding: try versionBody(versionID), as: UTF8.self)
    }

    /// Puts a version's text back. What the doc held until now becomes a version first, so restoring
    /// can itself be undone. The title stays, so links to the doc keep working.
    @discardableResult
    public func restoreVersion(_ versionID: UUID, of id: UUID) throws -> ReaderItem {
        let text = try versionText(versionID, of: id)
        let current = try item(id)
        try snapshot(id)
        return try saveNote(id, title: current.title, body: text, mime: MarkdownText.mime)
    }

    private func versionBody(_ versionID: UUID) throws -> Data {
        guard let sealed = try store.read(versionName(versionID)) else { throw ReaderError.notFound }
        return try ContentCipher.open(sealed, key: rootKey.objectKey(for: versionID, purpose: .docVersion), objectID: versionID)
    }

    private func writeVersions(_ versions: [DocVersion], of id: UUID) throws {
        guard !isClosed else { throw ReaderError.closed }
        let key = rootKey.objectKey(for: id, purpose: .docVersion)
        try store.write(try ContentCipher.seal(JSONEncoder().encode(versions), key: key, objectID: id), as: versionsName(id))
    }

    /// When a doc is gone for good, so is its history. A list that won't open still goes.
    private func removeVersions(of id: UUID) throws {
        for version in (try? versions(of: id)) ?? [] { try store.delete(versionName(version.id)) }
        try store.delete(versionsName(id))
    }

    // MARK: Files from outside (issue 102)

    /// Lets the viewers and Listen open a file that isn't the vault's, like one from Google Drive. Its ID
    /// must not be one of the vault's own. Only the latest few are held, and nothing is written.
    public func hold(_ item: ReaderItem, body: Data) throws {
        try hold(item, file: ReaderFile(data: body))
    }

    /// The same, for a file that's opened a piece at a time.
    public func hold(_ item: ReaderItem, file: ReaderFile) throws {
        guard !isClosed else { throw ReaderError.closed }
        guard try store.read(metaName(item.id)) == nil else { throw ReaderError.notFound }
        held[item.id] = (item, file)
        textCache[item.id] = nil
        heldOrder.removeAll { $0 == item.id }
        heldOrder.append(item.id)
        while heldOrder.count > Self.mostHeld {
            let gone = heldOrder.removeFirst()
            held[gone] = nil
            textCache[gone] = nil
        }
    }

    /// Forgets every held file, like after unlinking its folder.
    public func releaseHeld() {
        for id in heldOrder { textCache[id] = nil }
        held = [:]
        heldOrder = []
    }
}

/// The journal (issue 128), oldest day first. Notes added under a past day are listed with that day.
public struct JournalListing: Sendable, Equatable {
    /// Each day's own entry. A day with nothing written has none.
    public let entries: [ReaderItem]
    /// Notes, by the day they were added under, oldest first.
    public let notes: [String: [ReaderItem]]

    /// Days with any writing, for the month strip and the streak.
    public var days: Set<String> {
        Set(entries.filter { $0.byteCount > 0 }.compactMap(\.journal?.day))
            .union(notes.values.joined().filter { $0.byteCount > 0 }.compactMap(\.journal?.day))
    }

    public static let empty = JournalListing(entries: [], notes: [:])
}

extension ReaderVault {
    /// A day's entry has an ID from the day and the key, so two of this person's devices write the same
    /// entry, and the server can't tell which day an ID is.
    private func journalID(_ day: String) -> UUID {
        rootKey.derivedID(from: "reader-journal:\(day)")
    }

    /// When a journal item's day ended, if it has. Nil for anything else, or a day still open.
    fileprivate func journalLock(_ item: ReaderItem, now: Date = Date()) -> Date? {
        guard item.kind == .journal, let stamp = item.journal, stamp.isClosed(at: now) else { return nil }
        return stamp.locksAt ?? stamp.closedAt ?? .distantPast
    }

    /// Whether a closed journal item here must keep its words against what sync brought. An edit made
    /// before its day ended that arrives late still counts. After that, only the details around the
    /// words may change, like where Listen stopped.
    fileprivate func journalKeepsWords(_ incoming: SealedObject, theirs: ReaderItem) throws -> Bool {
        guard let meta = try store.read(metaName(incoming.id)), let mine = try? openedItem(meta, id: incoming.id),
              let lock = journalLock(mine), let stamp = mine.journal
        else { return false }
        let sameEntry = theirs.kind == .journal && theirs.journal?.day == stamp.day
            && theirs.journal?.zone == stamp.zone && theirs.journal?.about == stamp.about
        if sameEntry, theirs.updatedAt > mine.updatedAt, theirs.updatedAt <= lock { return false }
        guard sameEntry, theirs.title == mine.title else { return true }
        return try !file(of: incoming.id).sameBytes(as: openedFile(incoming, keep: 0))
    }

    /// Every journal item. One whose day has ended is marked closed here, the first time a device sees
    /// it, so a clock set back later can't reopen it.
    public func journal(now: Date = Date()) throws -> JournalListing {
        var entries: [String: [ReaderItem]] = [:]
        var notes: [String: [ReaderItem]] = [:]
        for var item in try everything().0 where item.kind == .journal {
            guard var stamp = item.journal else { continue }
            if stamp.closedAt == nil, stamp.isClosed(at: now), !isClosed {
                stamp.closedAt = stamp.locksAt ?? now
                item.journal = stamp
                // Locking isn't an edit, so the time stays.
                try writeMeta(item)
            }
            if let about = stamp.about {
                notes[about, default: []].append(item)
            } else {
                entries[stamp.day, default: []].append(item)
            }
        }
        // A day's entry is found by its sealed day, not its ID, which a change of key would change. A day
        // with two, as after one, shows the second as a note under it, so nothing goes missing.
        var days: [ReaderItem] = []
        for (day, found) in entries {
            let ordered = found.sorted(by: entryFirst(day))
            days.append(ordered[0])
            notes[day, default: []].append(contentsOf: ordered.dropFirst())
        }
        let byDay = { (a: ReaderItem, b: ReaderItem) in
            (a.journal?.day ?? "", a.createdAt) < (b.journal?.day ?? "", b.createdAt)
        }
        return JournalListing(entries: days.sorted(by: byDay), notes: notes.mapValues { $0.sorted(by: byDay) })
    }

    /// Of two entries for one day, the one this key names comes first, then the older.
    private func entryFirst(_ day: String) -> (ReaderItem, ReaderItem) -> Bool {
        let named = journalID(day)
        return { a, b in a.id == named ? b.id != named || a.createdAt < b.createdAt : b.id == named ? false : a.createdAt < b.createdAt }
    }

    /// The day's entry, by its sealed day.
    private func journalEntry(on day: String) throws -> ReaderItem? {
        if let named = try? item(journalID(day)), named.kind == .journal, named.journal?.about == nil { return named }
        return try everything().0
            .filter { $0.kind == .journal && $0.journal?.day == day && $0.journal?.about == nil }
            .min(by: entryFirst(day))
    }

    /// Today's entry, ready to write in. It isn't kept until something is written, so a day with nothing
    /// in it leaves nothing behind. When today's entry closed early because the person flew somewhere
    /// whose clock is behind, the next day's opens, since an entry that's over never reopens.
    public func journalToday(now: Date = Date(), zone: TimeZone = .current) throws -> ReaderItem {
        var day = JournalClock.day(of: now, in: zone)
        for _ in 0..<3 {
            let id = journalID(day)
            if let existing = try journalEntry(on: day) {
                if journalLock(existing, now: now) == nil { return existing }
            } else {
                let stamp = JournalStamp(day: day, zone: zone.identifier)
                if !stamp.isClosed(at: now) {
                    return ReaderItem(
                        id: id, kind: .journal, title: "Journal, \(JournalClock.heading(day))", collection: nil,
                        mime: MarkdownText.mime, byteCount: 0, createdAt: now, updatedAt: .distantPast,
                        listenPosition: 0, journal: stamp
                    )
                }
            }
            guard let next = JournalClock.day(day, adding: 1) else { break }
            day = next
        }
        throw ReaderError.journalClosed
    }

    /// A note to add under a past day. It belongs to today, so it locks when today does, and it isn't
    /// kept until something is written.
    public func journalNote(under day: String, now: Date = Date(), zone: TimeZone = .current) throws -> ReaderItem {
        let today = try journalToday(now: now, zone: zone)
        guard let stamp = today.journal, JournalClock.components(day) != nil, day < stamp.day else { throw ReaderError.notFound }
        return ReaderItem(
            id: UUID(), kind: .journal, title: "Note on \(JournalClock.short(day))", collection: nil,
            mime: MarkdownText.mime, byteCount: 0, createdAt: now, updatedAt: .distantPast, listenPosition: 0,
            journal: JournalStamp(day: stamp.day, zone: stamp.zone, about: day)
        )
    }

    /// The words of a journal entry or note. Nothing written yet reads as empty.
    public func journalText(of id: UUID) throws -> String {
        do {
            _ = try item(id)
        } catch ReaderError.notFound {
            return ""
        }
        return String(decoding: try body(of: id), as: UTF8.self)
    }

    /// Saves today's entry or a note from the editor. A day that's over is refused, whatever the editor
    /// thinks. `basedOn` is the version the editor loaded: when another device saved since, what was typed
    /// is kept as a note under the same day, so neither is lost.
    public func saveJournal(_ draft: ReaderItem, body: String, basedOn: Date, now: Date = Date()) throws -> NoteSave {
        guard draft.kind == .journal, let draftStamp = draft.journal else { throw ReaderError.notANote }
        let current = try? item(draft.id)
        // The kept copy says what this is, so an editor can't move an entry to another day.
        let stamp = current?.journal ?? draftStamp
        guard current == nil || current?.kind == .journal else { throw ReaderError.notANote }
        guard !stamp.isClosed(at: now) else { throw ReaderError.journalClosed }
        // A new entry takes the day's own ID. One already kept may have an older one, from before a key change.
        if stamp.about == nil, current == nil, draft.id != journalID(stamp.day) { throw ReaderError.notFound }
        let data = Data(body.utf8)
        guard data.count <= Self.maxTextBytes else { throw ReaderError.tooLarge }
        if let current, current.updatedAt != basedOn {
            let copy = ReaderItem(
                id: UUID(), kind: .journal, title: "Conflict copy", collection: nil, mime: MarkdownText.mime,
                byteCount: data.count, createdAt: now, updatedAt: now, listenPosition: 0,
                journal: JournalStamp(day: stamp.day, zone: stamp.zone, about: stamp.about ?? stamp.day)
            )
            try writeBody(data, id: copy.id)
            try writeMeta(copy)
            return .keptAsCopy(copy)
        }
        // Nothing written in a day that has no entry yet leaves no entry.
        if current == nil, data.isEmpty { return .saved(draft) }
        var updated = current ?? draft
        updated.byteCount = data.count
        updated.updatedAt = now
        if current == nil { try store.delete(deletionName(draft.id)) }
        try writeBody(data, id: updated.id)
        try writeMeta(updated)
        return .saved(updated)
    }
}
