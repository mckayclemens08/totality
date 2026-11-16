import Foundation
import PDFKit
import TotalityCore

/// Bytes that can be read a range at a time: a file opened from its sealed pieces, one held in memory, or
/// one the person is importing. Readers of EPUB, Word and PDF files go through this, so a big file is
/// never held whole.
protocol ByteSource: Sendable {
    var count: Int { get }
    /// The bytes in `range`, clamped to the source.
    func read(_ range: Range<Int>) throws -> Data
}

extension Data: ByteSource {
    func read(_ range: Range<Int>) throws -> Data {
        let lower = Swift.max(0, Swift.min(count, range.lowerBound))
        let upper = Swift.max(lower, Swift.min(count, range.upperBound))
        return subdata(in: (startIndex + lower)..<(startIndex + upper))
    }
}

/// A plain file on the device the person chose to import, read a range at a time. It's theirs and
/// already unsealed. Nothing here writes to it.
final class PlainFileSource: ByteSource, @unchecked Sendable {
    let count: Int
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        count = Int(try handle.seekToEnd())
    }

    deinit {
        try? handle.close()
    }

    func read(_ range: Range<Int>) throws -> Data {
        let lower = max(0, min(count, range.lowerBound))
        let upper = max(lower, min(count, range.upperBound))
        guard upper > lower else { return Data() }
        return try lock.withLock {
            try handle.seek(toOffset: UInt64(lower))
            guard let data = try handle.read(upToCount: upper - lower), data.count == upper - lower else { throw ReaderError.notReadable }
            return data
        }
    }
}

/// A Reader file's bytes, opened from its sealed copy. A file sealed in pieces (issue 124) is read a piece
/// at a time and only a few pieces stay in memory. An older file, sealed whole, is in memory as it always
/// was. Neither is ever written anywhere unsealed.
public final class ReaderFile: ByteSource, @unchecked Sendable {
    /// The most of a file that's ever read whole into memory, for the viewers that need it so: images,
    /// plain text and web pages. Anything bigger is read in pieces, or not at all.
    public static let wholeLimit = 64 * 1024 * 1024
    /// Pieces kept open in memory: four 4 MB pieces, so scrolling back and forth doesn't unseal them again.
    static let piecesKept = 4

    private enum Source {
        case data(Data)
        case pieces(ChunkedCipher.Reader)
    }

    private let source: Source

    init(data: Data) {
        source = .data(data)
    }

    init(pieces: ChunkedCipher.Reader) {
        source = .pieces(pieces)
    }

    public var count: Int {
        switch source {
        case .data(let data): data.count
        case .pieces(let reader): reader.plainLength
        }
    }

    /// Whether it opens a piece at a time.
    public var isPieces: Bool {
        if case .pieces = source { return true }
        return false
    }

    func read(_ range: Range<Int>) throws -> Data {
        switch source {
        case .data(let data): return try data.read(range)
        case .pieces(let reader): return try reader.read(range)
        }
    }

    /// The whole file, for the viewers that need it whole. Refused past `limit`, so a big file can't
    /// fill the phone's memory.
    public func whole(limit: Int = ReaderFile.wholeLimit) throws -> Data {
        switch source {
        case .data(let data):
            return data
        case .pieces(let reader):
            guard reader.plainLength <= limit else { throw ReaderError.tooLargeToShow }
            return try reader.read(0..<reader.plainLength)
        }
    }

    /// Opens every piece once, so a file damaged anywhere is refused before it's kept.
    func verify() throws {
        if case .pieces(let reader) = source { try reader.verifyAll() }
    }

    /// Whether two files hold the same bytes, compared a piece at a time.
    func sameBytes(as other: ReaderFile) throws -> Bool {
        guard count == other.count else { return false }
        let step = 4 * 1024 * 1024
        var start = 0
        while start < count {
            let range = start..<min(count, start + step)
            guard try read(range) == other.read(range) else { return false }
            start = range.upperBound
        }
        return true
    }

    /// Seals these bytes, a piece at a time, under another object's ID and key, into `output`.
    func reseal(to output: URL, key: ObjectKey, objectID: UUID) throws {
        let writer = try ChunkedCipher.Writer(to: output, plainLength: count, key: key, objectID: objectID, chunkSize: ReaderVault.pieceSize)
        var start = 0
        while start < count {
            let range = start..<min(count, start + ReaderVault.pieceSize)
            try writer.append(read(range))
            start = range.upperBound
        }
        try writer.finish()
    }

    /// The file as a PDF that reads only the pages it shows, through `PagedPDF`.
    func pdf() -> PDFDocument? {
        switch source {
        case .data(let data): PDFDocument(data: data)
        case .pieces: PagedPDF.document(self)
        }
    }
}

/// A PDF that PDFKit reads a range at a time, through a CoreGraphics data provider, so a 1 GB scan never
/// sits in memory whole. PDFKit has no public way to take a provider, so this uses `initWithProvider:`,
/// the initializer PDFKit's own documents use, checked for at run time. Where it isn't there, a file up to
/// `ReaderFile.wholeLimit` opens in memory instead, and a bigger one says it can't be shown.
enum PagedPDF {
    private static let initializer = NSSelectorFromString("initWithProvider:")

    static var isAvailable: Bool {
        PDFDocument.instancesRespond(to: initializer)
    }

    static func document(_ file: ReaderFile) -> PDFDocument? {
        guard isAvailable else {
            return (try? file.whole()).flatMap(PDFDocument.init(data:))
        }
        let box = Unmanaged.passRetained(file)
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let file = Unmanaged<ReaderFile>.fromOpaque(info).takeUnretainedValue()
                let start = Int(position)
                guard start >= 0, start < file.count, count > 0 else { return 0 }
                // A piece that won't open reads as the end of the file, so PDFKit stops there.
                guard let data = try? file.read(start..<(start + min(count, file.count - start))) else { return 0 }
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                return data.count
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<ReaderFile>.fromOpaque(info).release()
            }
        )
        // Whether CoreGraphics calls releaseInfo when it can't make the provider isn't documented, so the
        // retain is left in place then: a file object kept a little too long beats one freed twice.
        guard let provider = CGDataProvider(directInfo: box.toOpaque(), size: off_t(file.count), callbacks: &callbacks) else {
            return nil
        }
        // Declared as a protocol so Swift calls alloc and init with the usual ownership rules.
        let maker = unsafeBitCast(PDFDocument.self, to: ProvidedPDF.Type.self)
        guard let opened = maker.init(provider: provider) as? PDFDocument, opened.pageCount > 0 else { return nil }
        return opened
    }
}

/// PDFKit's own initializer for a document read through a data provider. It isn't in the public headers,
/// so `PagedPDF` checks it's there before calling it.
@objc private protocol ProvidedPDF {
    init?(provider: CGDataProvider)
}
