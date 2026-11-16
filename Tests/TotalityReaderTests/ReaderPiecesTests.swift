import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import TotalityCore
@testable import TotalityReader

/// A folder of real files, which pieces need.
private func fileStore() throws -> FileBlobStore {
    try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pieces-\(UUID().uuidString)"))
}

/// Bytes that don't repeat, so a piece swapped for another can't pass for it.
private func varied(_ count: Int) -> Data {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes[index] = UInt8(truncatingIfNeeded: state)
    }
    return Data(bytes)
}

private func plainFile(_ data: Data, named name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

/// A scanned book's pages: a grainy picture on each, too noisy to shrink, and a line of real text, so the
/// file runs to several pieces and still has words to find.
func makeScannedPDF(pages: [String], side: Int = 900) throws -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = try #require(CGDataConsumer(data: data))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    for (number, text) in pages.enumerated() {
        let grain = varied(side * side * 4).dropFirst(number)
        let provider = try #require(CGDataProvider(data: Data(grain.prefix(side * side * 4)) as CFData))
        let picture = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        context.beginPDFPage(nil)
        context.draw(picture, in: CGRect(x: 56, y: 140, width: 500, height: 500))
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        )
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

@Suite struct ReaderPiecesTests {
    let store: FileBlobStore
    let key: ContentRootKey
    let vault: ReaderVault

    init() throws {
        store = try fileStore()
        key = try ContentRootKey.generate()
        vault = ReaderVault(store: store, rootKey: key)
    }

    private func piecesURL(_ id: UUID) throws -> URL {
        try store.location(of: "\(id.uuidString.lowercased()).pieces")
    }

    @Test("A file is sealed in 4 MB pieces and opens a range at a time")
    func sealsInPieces() async throws {
        let data = varied(9 * 1024 * 1024 + 123)
        let item = try await vault.importFile(at: try plainFile(data, named: "Field recordings.bin"), filename: "Field recordings.bin")
        #expect(item.byteCount == data.count)
        #expect(item.title == "Field recordings")
        let names = try store.names()
        #expect(names.contains("\(item.id.uuidString.lowercased()).pieces"))
        #expect(!names.contains("\(item.id.uuidString.lowercased()).body"))
        let sealed = try Data(contentsOf: try piecesURL(item.id))
        #expect(sealed.count == ChunkedCipher.sealedLength(plain: data.count, chunkSize: ReaderVault.pieceSize))
        #expect(sealed.range(of: data.subdata(in: 5_000_000..<5_000_064)) == nil)
        let file = try await vault.file(of: item.id)
        #expect(file.isPieces)
        #expect(file.count == data.count)
        #expect(try file.read(4_194_000..<4_195_000) == data.subdata(in: 4_194_000..<4_195_000))
        #expect(try file.read(9_437_000..<20_000_000) == data.subdata(in: 9_437_000..<data.count))
        // Nothing unsealed is left beside it.
        #expect(names.allSatisfy { !$0.hasSuffix("-importing") })
    }

    @Test("Pieces swapped, cut short, or added to never open")
    func reorderedOrTruncatedPiecesAreRefused() async throws {
        let data = varied(9 * 1024 * 1024)
        let item = try await vault.importFile(at: try plainFile(data, named: "Atlas.bin"), filename: "Atlas.bin")
        let url = try piecesURL(item.id)
        let whole = try Data(contentsOf: url)
        let stride = ReaderVault.pieceSize + 40
        var swapped = [UInt8](whole)
        let first = Array(swapped[13..<13 + stride])
        swapped.replaceSubrange(13..<13 + stride, with: swapped[13 + stride..<13 + 2 * stride])
        swapped.replaceSubrange(13 + stride..<13 + 2 * stride, with: first)
        try Data(swapped).write(to: url)
        let reordered = try await vault.file(of: item.id)
        #expect(throws: CryptoError.authenticationFailed) { try reordered.read(0..<10) }
        await #expect(throws: CryptoError.authenticationFailed) { try await vault.verifiedObject(item.id) }

        try whole.dropLast(stride).write(to: url)
        await #expect(throws: CryptoError.malformedCiphertext) { try await vault.file(of: item.id) }
        try (whole + Data(count: 40)).write(to: url)
        await #expect(throws: CryptoError.malformedCiphertext) { try await vault.file(of: item.id) }
    }

    @Test("A file sealed whole, from before pieces, still opens and syncs as it did")
    func oldSinglePieceFilesStillOpen() async throws {
        let id = UUID()
        let words = Data("It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.".utf8)
        let now = Date()
        let item = ReaderItem(
            id: id, kind: .file, title: "Pride and Prejudice", collection: nil, mime: "text/plain",
            byteCount: words.count, createdAt: now, updatedAt: now, listenPosition: 0
        )
        try store.write(try ContentCipher.seal(words, key: key.objectKey(for: id, purpose: .content), objectID: id), as: "\(id.uuidString.lowercased()).body")
        try store.write(try ContentCipher.seal(JSONEncoder().encode(item), key: key.objectKey(for: id, purpose: .metadata), objectID: id), as: "\(id.uuidString.lowercased()).meta")
        let file = try await vault.file(of: id)
        #expect(!file.isPieces)
        #expect(try await vault.text(of: id).hasPrefix("It is a truth"))
        let object = try #require(try await vault.verifiedObject(id))
        #expect(object.body != nil && object.bodyFile == nil)
    }

    private func copied(_ object: SealedObject) throws -> SealedObject {
        try copiedObject(object)
    }

    @Test("Sync carries pieces as a file, and another device with the key reads them")
    func syncsAsAFile() async throws {
        let data = varied(6 * 1024 * 1024 + 7)
        let item = try await vault.importFile(at: try plainFile(data, named: "Survey.bin"), filename: "Survey.bin")
        let object = try #require(try await vault.verifiedObject(item.id))
        let file = try #require(object.bodyFile)
        #expect(object.body == nil)
        #expect(file.count == ChunkedCipher.sealedLength(plain: data.count, chunkSize: ReaderVault.pieceSize))
        // The hash is the same as for the same bytes held in memory, so both forms sync alike.
        let inMemory = SealedObject(id: object.id, kind: object.kind, meta: object.meta, body: try Data(contentsOf: file.url))
        #expect(inMemory.hash == object.hash)
        #expect(inMemory.bodyHash == object.bodyHash)
        #expect(try await vault.sealedHash(of: item.id) == object.hash)

        let otherStore = try fileStore()
        let other = ReaderVault(store: otherStore, rootKey: key)
        try await other.store(try copied(object), ifLocalHash: nil)
        #expect(try await other.file(of: item.id).read(0..<data.count) == data)
        #expect(try await other.sealedHash(of: item.id) == object.hash)

        // A small file that came down whole is put in a file too.
        let third = ReaderVault(store: try fileStore(), rootKey: key)
        try await third.store(inMemory, ifLocalHash: nil)
        #expect(try await third.file(of: item.id).isPieces)
        #expect(try await third.file(of: item.id).read(0..<64) == data.prefix(64))
    }

    @Test("A body that changed under sync can't be stored, and a damaged one is refused")
    func syncRefusesDamage() async throws {
        let item = try await vault.importFile(at: try plainFile(varied(5 * 1024 * 1024), named: "Maps.bin"), filename: "Maps.bin")
        let object = try #require(try await vault.sealedObject(item.id))
        let other = ReaderVault(store: try fileStore(), rootKey: key)
        let landed = try copied(object)
        var bytes = try Data(contentsOf: landed.bodyFile!.url)
        bytes[bytes.count - 100] ^= 0x01
        try bytes.write(to: landed.bodyFile!.url)
        let damaged = SealedObject(id: object.id, kind: object.kind, meta: object.meta, bodyFile: try SealedFile(reading: landed.bodyFile!.url))
        await #expect(throws: CryptoError.authenticationFailed) { try await other.store(damaged, ifLocalHash: nil) }
        #expect(try await other.list().items.isEmpty)
    }

    @Test("Recently Deleted keeps the pieces, and deleting for good removes them")
    func trashAndRestore() async throws {
        let data = varied(5 * 1024 * 1024)
        let item = try await vault.importFile(at: try plainFile(data, named: "Letters.bin"), filename: "Letters.bin")
        try await vault.delete(item.id)
        #expect(try store.names().contains("\(item.id.uuidString.lowercased()).pieces.trash"))
        await #expect(throws: ReaderError.notFound) { try await vault.file(of: item.id) }
        try await vault.restore(item.id)
        #expect(try await vault.file(of: item.id).read(0..<data.count) == data)
        try await vault.delete(item.id)
        try await vault.deleteForever(item.id)
        #expect(try store.names().allSatisfy { !$0.contains(item.id.uuidString.lowercased()) || $0.hasSuffix(".deleted") })
    }

    @Test("Two versions of a file in pieces keep the older as a copy, sealed under its own ID")
    func conflictCopy() async throws {
        let item = try await vault.importFile(at: try plainFile(varied(5 * 1024 * 1024), named: "Plan.bin"), filename: "Plan.bin")
        let local = try #require(try await vault.sealedObject(item.id))
        let otherStore = try fileStore()
        let other = ReaderVault(store: otherStore, rootKey: key)
        try await other.store(try copied(local), ifLocalHash: nil)
        // The other device renames it, so the two versions differ.
        try await other.rename(item.id, to: "Plan, revised")
        let remote = try #require(try await other.sealedObject(item.id))
        _ = try await vault.resolveConflict(local: local, remote: try copied(remote))
        let titles = try await vault.list().items.map(\.title)
        #expect(titles.contains { $0.hasSuffix("(conflict copy)") })
        let copy = try #require(try await vault.list().items.first { $0.title.hasSuffix("(conflict copy)") })
        #expect(try await vault.file(of: copy.id).isPieces)
        #expect(try await vault.file(of: copy.id).read(0..<32) == varied(32))
    }

    @Test("A scanned PDF in several pieces opens page by page, with its words")
    func pagedPDF() async throws {
        let pages = [
            "Plate one: the harbour at Lyme, drawn in 1811.",
            "Plate two: Pemberley from the north lawn.",
            "Plate three: the road to Meryton after rain.",
        ]
        let pdf = try makeScannedPDF(pages: pages)
        #expect(pdf.count > ReaderVault.pieceSize)
        let item = try await vault.importFile(at: try plainFile(pdf, named: "Plates.pdf"), filename: "Plates.pdf")
        let file = try await vault.file(of: item.id)
        #expect(file.isPieces)
        let document = try #require(file.pdf())
        #expect(document.pageCount == 3)
        #expect(document.page(at: 1)?.string?.contains("Pemberley") == true)
        #expect(try await vault.text(of: item.id).contains("road to Meryton"))
        #expect(ReadableText.pageMap(file).pages.count == 3)
        let hits = try await vault.search("Pemberley lawn")
        #expect(hits.map(\.item.id) == [item.id])
    }

    @Test("A PDF too big to hold whole opens through CoreGraphics, a page at a time, with its words and where they sit")
    func largePDF() async throws {
        let pages = [
            "Plate one: the harbour at Lyme, drawn in 1811.",
            "Plate two: Pemberley from the north lawn.",
            "Plate three: the road to Meryton after rain.",
        ]
        let item = try await vault.importFile(at: try plainFile(try makeScannedPDF(pages: pages), named: "Plates.pdf"), filename: "Plates.pdf")
        let file = try await vault.file(of: item.id)
        // As though it were over the 64 MB a viewer holds whole.
        guard case .large(let pdf) = try #require(PDFSource.open(file, wholeLimit: 1024)) else {
            Issue.record("Opened whole")
            return
        }
        #expect(pdf.pageCount == 3)
        #expect(!pdf.isLocked)
        #expect(pdf.pageTexts()[1].contains("Pemberley"))
        let image = try #require(pdf.image(of: 0, pixelWidth: 300))
        #expect(image.width == 300)
        #expect(image.height == 388)
        // A word's place on its own page, as Read along marks it, and back again for a tap.
        let page = try #require(pdf.textPage(2))
        let text = try #require(page.string)
        let found = (text as NSString).range(of: "Meryton")
        let selection = try #require(page.selection(for: found))
        let shown = pdf.viewRect(selection.bounds(for: page), page: 2, width: 306)
        #expect(shown.minY > 0 && shown.minY < 120)
        let back = try #require(pdf.pagePoint(CGPoint(x: shown.midX, y: shown.midY), page: 2, width: 306))
        #expect((found.location..<(found.location + found.length)).contains(page.characterIndex(at: back)))
        // Its text and page map agree, so Listen's place falls on the right page.
        let map = PDFPageMap(whole: pdf.pageTexts().joined(separator: "\n"), pages: pdf.pageTexts())
        #expect(map.pages.map(\.index) == [0, 1, 2])
    }

    @Test("A book in pieces is read a part at a time, for its title, its pages and its words")
    func epubByParts() async throws {
        let item = try await vault.importFile(at: try plainFile(GutenbergBook.epub(), named: "pg1342.epub"), filename: "pg1342.epub")
        #expect(item.title == "Pride and Prejudice")
        let file = try await vault.file(of: item.id)
        #expect(file.isPieces)
        #expect(try await vault.text(of: item.id).contains("truth universally acknowledged"))
        let source = try #require(await BookSource(data: file, mime: ReadableText.epubMime, text: nil))
        #expect(await !source.chapters.isEmpty)
    }

    @Test("Up to 5 GB is taken, and more is refused before anything is read")
    func theRealLimit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("huge-\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        // Sparse, so nothing is really written.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ReaderVault.maxFileBytes + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ReaderError.tooLarge) { try await vault.importFile(at: url, filename: "huge.pdf") }
        #expect(try store.names().isEmpty)
        #expect(ReaderVault.maxFileBytes > 4 * 1024 * 1024 * 1024)
        #expect(ChunkedCipher.sealedLength(plain: ReaderVault.maxFileBytes, chunkSize: ReaderVault.pieceSize) <= SealedStoreClient.maxBlob)
    }

    @Test("Progress is heard as the pieces are sealed")
    func progress() async throws {
        let heard = Heard()
        _ = try await vault.importFile(at: try plainFile(varied(9 * 1024 * 1024), named: "Long.bin"), filename: "Long.bin") { heard.add($0) }
        let fractions = heard.all
        #expect(fractions.count == 3)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }

    @Test("A file too big to hold whole is refused by a viewer that needs it whole, but its pieces still read")
    func wholeLimit() throws {
        let pieces = try sealedReader(varied(ReaderFile.wholeLimit + 1))
        let file = ReaderFile(pieces: pieces)
        #expect(throws: ReaderError.tooLargeToShow) { try file.whole() }
        #expect(try file.read(0..<8).count == 8)
    }

    private func sealedReader(_ data: Data) throws -> ChunkedCipher.Reader {
        let id = UUID()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("whole-\(UUID().uuidString)")
        try ReaderFile(data: data).reseal(to: output, key: key.objectKey(for: id, purpose: .readerPieces), objectID: id)
        return try ChunkedCipher.Reader(file: output, key: key.objectKey(for: id, purpose: .readerPieces), objectID: id)
    }
}

/// The object with its file copied, as a download would arrive.
private func copiedObject(_ object: SealedObject) throws -> SealedObject {
    let file = try #require(object.bodyFile)
    let landed = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: file.url, to: landed)
    return SealedObject(id: object.id, kind: object.kind, meta: object.meta, bodyFile: try SealedFile(reading: landed))
}

@Suite struct ReaderPiecesTwoUserTests {
    let store: FileBlobStore
    let vault: ReaderVault

    init() throws {
        store = try fileStore()
        vault = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
    }

    private func copied(_ object: SealedObject) throws -> SealedObject {
        try copiedObject(object)
    }

    @Test("Another account's key opens none of the pieces")
    func twoUsers() async throws {
        let item = try await vault.importFile(at: try plainFile(varied(5 * 1024 * 1024), named: "Diary.bin"), filename: "Diary.bin")
        let user2 = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        await #expect(throws: CryptoError.self) { try await user2.file(of: item.id).read(0..<16) }
        await #expect(throws: CryptoError.self) { try await user2.verifiedObject(item.id) }
        // User 2 gets nothing even from the sealed copy as sync carries it.
        let object = try #require(try await vault.sealedObject(item.id))
        let theirs = ReaderVault(store: try fileStore(), rootKey: try ContentRootKey.generate())
        await #expect(throws: CryptoError.self) { try await theirs.store(try copied(object), ifLocalHash: nil) }
        #expect(try await theirs.list().items.isEmpty)
    }

}

private final class TestKeys: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]
    func load(_ name: String) throws -> Data? { lock.withLock { secrets[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { secrets[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
}

@Suite struct ReaderPiecesKeyMoveTests {
    @Test("A change of key moves every piece file, in the library and in Recently Deleted")
    func keyMove() async throws {
        let files = try fileStore()
        let ring = ContentKeyRing(keys: TestKeys(), areas: [
            SealedArea(files: files, purposes: ReaderVault.sealedPurposes, chunked: ReaderVault.chunkedPurposes),
        ])
        let old = try ring.current()
        let vault = ReaderVault(store: files, rootKey: old)
        let kept = varied(5 * 1024 * 1024)
        let item = try await vault.importFile(at: try plainFile(kept, named: "Kept.bin"), filename: "Kept.bin")
        let gone = try await vault.importFile(at: try plainFile(varied(4 * 1024 * 1024 + 1), named: "Gone.bin"), filename: "Gone.bin")
        try await vault.delete(gone.id)
        await vault.close()

        let new = try ContentRootKey.generate()
        let report = try ring.adopt(new)
        #expect(report.unreadable == 0)
        let moved = ReaderVault(store: files, rootKey: new)
        #expect(try await moved.file(of: item.id).read(0..<kept.count) == kept)
        try await moved.restore(gone.id)
        #expect(try await moved.file(of: gone.id).read(0..<8) == varied(8))
        await #expect(throws: CryptoError.self) { try await ReaderVault(store: files, rootKey: old).file(of: item.id).read(0..<8) }
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

@Suite struct ChunkedWriterTests {
    let key = try! ContentRootKey.generate().objectKey(for: UUID(), purpose: .readerPieces)
    let id = UUID()

    private func output() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID().uuidString)")
    }

    @Test("Bytes that arrive in any sizes seal the same as a file read whole")
    func anySizes() throws {
        let data = varied(10_500)
        let url = output()
        let writer = try ChunkedCipher.Writer(to: url, plainLength: data.count, key: key, objectID: id, chunkSize: 1_000)
        var start = 0
        for size in [1, 999, 2_500, 3, 7_000] where start < data.count {
            let end = min(data.count, start + size)
            try writer.append(data.subdata(in: start..<end))
            start = end
        }
        try writer.finish()
        let reader = try ChunkedCipher.Reader(file: url, key: key, objectID: id)
        #expect(try reader.read(0..<data.count) == data)
    }

    @Test("More than the length, or less, is refused")
    func wrongLength() throws {
        let over = try ChunkedCipher.Writer(to: output(), plainLength: 10, key: key, objectID: id, chunkSize: 4)
        #expect(throws: CryptoError.malformedCiphertext) { try over.append(Data(count: 11)) }
        let short = try ChunkedCipher.Writer(to: output(), plainLength: 10, key: key, objectID: id, chunkSize: 4)
        try short.append(Data(count: 9))
        #expect(throws: CryptoError.malformedCiphertext) { try short.finish() }
    }
}
