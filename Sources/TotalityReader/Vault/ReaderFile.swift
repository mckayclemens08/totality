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
            try autoreleasepool {
                try handle.seek(toOffset: UInt64(lower))
                guard let data = try handle.read(upToCount: upper - lower), data.count == upper - lower else { throw ReaderError.notReadable }
                return Data(data)
            }
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

    /// The file as a PDF in PDFKit, when it fits in memory. A bigger one opens as a `LargePDF`.
    func pdf() -> PDFDocument? {
        guard count <= Self.wholeLimit else { return nil }
        return (try? whole()).flatMap(PDFDocument.init(data:))
    }
}
