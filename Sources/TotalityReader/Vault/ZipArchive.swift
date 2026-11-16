import Compression
import Foundation

/// Reads files out of a zip, for EPUB and Word files, a part at a time: the directory first, then only the
/// part asked for. The zip itself is read through a `ByteSource`, so a big book sealed in pieces is never
/// opened whole (issue 124). These files come from outside the app, so every number in them is
/// distrusted: nothing is read past the end, nothing touches the disk, and a file can't unpack to more
/// than the budget however small it looks.
struct ZipArchive {
    static let maxEntries = 50_000
    /// The most one part may unpack to. It's held in memory while it's shown, so it stays well short of
    /// what a phone can spare. A picture in a book is a few megabytes.
    static let maxEntryBytes = 128 * 1024 * 1024
    /// The most a directory may take, which 50,000 long names fit in.
    static let maxDirectoryBytes = 16 * 1024 * 1024
    /// The most an archive unpacks over its life. A book read cover to cover, pictures and all, is far less.
    static let defaultBudget = 4 * 1024 * 1024 * 1024

    private struct Entry {
        let isEncrypted: Bool
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    private let source: any ByteSource
    private var entries: [String: Entry] = [:]
    private var budget: Int

    init(_ source: any ByteSource, budget: Int = ZipArchive.defaultBudget) throws {
        self.source = source
        self.budget = budget
        // The end record is in the last 22 bytes, or before a comment of up to 64 KB.
        let tailStart = max(0, source.count - 22 - 0xFFFF)
        let tail = Bytes(try source.read(tailStart..<source.count), at: tailStart)
        let end = try Self.endRecord(in: tail)
        let count = try tail.u16(end + 10)
        let directorySize = try tail.u32(end + 12)
        let directoryStart = try tail.u32(end + 16)
        // These values mean a zip64 file, which no EPUB or Word file needs.
        guard count != 0xFFFF, directoryStart != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF, count <= Self.maxEntries,
              directorySize <= Self.maxDirectoryBytes, directoryStart + directorySize <= end
        else { throw ReaderError.notReadable }
        let directory = Bytes(try source.read(directoryStart..<(directoryStart + directorySize)), at: directoryStart)
        guard directory.end == directoryStart + directorySize else { throw ReaderError.notReadable }
        var position = directoryStart
        for _ in 0..<count {
            guard try directory.u32(position) == 0x0201_4B50 else { throw ReaderError.notReadable }
            let nameLength = try directory.u16(position + 28)
            let extraLength = try directory.u16(position + 30)
            let commentLength = try directory.u16(position + 32)
            let name = try directory.slice(position + 46, nameLength)
            entries[String(decoding: name, as: UTF8.self)] = Entry(
                isEncrypted: try directory.u16(position + 8) & 1 != 0,
                method: UInt16(try directory.u16(position + 10)),
                compressedSize: try directory.u32(position + 20),
                size: try directory.u32(position + 24),
                headerOffset: try directory.u32(position + 42)
            )
            position += 46 + nameLength + extraLength + commentLength
        }
    }

    var names: [String] {
        Array(entries.keys)
    }

    /// How big a part unpacks to, without unpacking it. Nil when there's no such part.
    func size(of name: String) -> Int? {
        entries[name]?.size
    }

    /// Nil when there's no such file. Throws when the file exists but can't be read safely.
    mutating func read(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard !entry.isEncrypted, entry.size <= Self.maxEntryBytes, entry.size <= budget,
              entry.compressedSize <= Self.maxEntryBytes + 1024 * 1024
        else { throw ReaderError.notReadable }
        let header = Bytes(try source.read(entry.headerOffset..<(entry.headerOffset + 30)), at: entry.headerOffset)
        guard try header.u32(entry.headerOffset) == 0x0403_4B50 else { throw ReaderError.notReadable }
        let start = entry.headerOffset + 30 + (try header.u16(entry.headerOffset + 26)) + (try header.u16(entry.headerOffset + 28))
        guard start <= source.count, entry.compressedSize <= source.count - start else { throw ReaderError.notReadable }
        let compressed = try source.read(start..<(start + entry.compressedSize))
        guard compressed.count == entry.compressedSize else { throw ReaderError.notReadable }
        budget -= entry.size
        switch entry.method {
        case 0:
            guard compressed.count == entry.size else { throw ReaderError.notReadable }
            return compressed
        case 8:
            return try Self.inflate(compressed, to: entry.size)
        default:
            throw ReaderError.notReadable
        }
    }

    private static func inflate(_ source: Data, to size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: size)
        let written = source.withUnsafeBytes { input -> Int in
            guard let base = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, size, base, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw ReaderError.notReadable }
        return Data(output)
    }

    /// The directory's end marker, found from the back because a comment can follow it.
    private static func endRecord(in tail: Bytes) throws -> Int {
        guard tail.end - tail.start >= 22 else { throw ReaderError.notReadable }
        var position = tail.end - 22
        while position >= tail.start {
            if try tail.u32(position) == 0x0605_4B50 { return position }
            position -= 1
        }
        throw ReaderError.notReadable
    }

    /// Some of the zip's bytes, addressed by where they sit in the whole zip.
    private struct Bytes {
        let bytes: [UInt8]
        let start: Int

        init(_ data: Data, at start: Int) {
            bytes = [UInt8](data)
            self.start = start
        }

        var end: Int { start + bytes.count }

        func slice(_ position: Int, _ length: Int) throws -> ArraySlice<UInt8> {
            let from = position - start
            guard from >= 0, length >= 0, from <= bytes.count, length <= bytes.count - from else { throw ReaderError.notReadable }
            return bytes[from..<(from + length)]
        }

        func u16(_ position: Int) throws -> Int {
            let part = try slice(position, 2)
            return Int(part[part.startIndex]) | Int(part[part.startIndex + 1]) << 8
        }

        func u32(_ position: Int) throws -> Int {
            let part = try slice(position, 4)
            return (0..<4).reduce(0) { $0 | Int(part[part.startIndex + $1]) << ($1 * 8) }
        }
    }
}
