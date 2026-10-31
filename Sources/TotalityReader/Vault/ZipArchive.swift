import Compression
import Foundation

/// Reads files out of a zip held in memory, for EPUB and Word files. These come from outside the app,
/// so every number in them is distrusted: nothing is read past the end, nothing touches the disk, and
/// a file can't unpack to more than the budget however small it looks.
struct ZipArchive {
    static let maxEntries = 50_000
    static let maxEntryBytes = 64 * 1024 * 1024
    static let defaultBudget = 256 * 1024 * 1024

    private struct Entry {
        let isEncrypted: Bool
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    private let bytes: [UInt8]
    private var entries: [String: Entry] = [:]
    private var budget: Int

    init(_ data: Data, budget: Int = ZipArchive.defaultBudget) throws {
        bytes = [UInt8](data)
        self.budget = budget
        let end = try endRecord()
        let count = try u16(end + 10)
        let directorySize = try u32(end + 12)
        let directoryStart = try u32(end + 16)
        // These values mean a zip64 file, which no EPUB or Word file needs.
        guard count != 0xFFFF, directoryStart != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF, count <= Self.maxEntries,
              directoryStart + directorySize <= end
        else { throw ReaderError.notReadable }
        var position = directoryStart
        for _ in 0..<count {
            guard try u32(position) == 0x0201_4B50 else { throw ReaderError.notReadable }
            let nameLength = try u16(position + 28)
            let extraLength = try u16(position + 30)
            let commentLength = try u16(position + 32)
            let name = try slice(position + 46, nameLength)
            entries[String(decoding: name, as: UTF8.self)] = Entry(
                isEncrypted: try u16(position + 8) & 1 != 0,
                method: UInt16(try u16(position + 10)),
                compressedSize: try u32(position + 20),
                size: try u32(position + 24),
                headerOffset: try u32(position + 42)
            )
            position += 46 + nameLength + extraLength + commentLength
        }
    }

    var names: [String] {
        Array(entries.keys)
    }

    /// Nil when there's no such file. Throws when the file exists but can't be read safely.
    mutating func read(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard !entry.isEncrypted, entry.size <= Self.maxEntryBytes, entry.size <= budget else {
            throw ReaderError.notReadable
        }
        guard try u32(entry.headerOffset) == 0x0403_4B50 else { throw ReaderError.notReadable }
        let start = entry.headerOffset + 30 + (try u16(entry.headerOffset + 26)) + (try u16(entry.headerOffset + 28))
        let source = try slice(start, entry.compressedSize)
        budget -= entry.size
        switch entry.method {
        case 0:
            guard source.count == entry.size else { throw ReaderError.notReadable }
            return Data(source)
        case 8:
            return try inflate(source, to: entry.size)
        default:
            throw ReaderError.notReadable
        }
    }

    private func inflate(_ source: ArraySlice<UInt8>, to size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: size)
        let written = source.withUnsafeBufferPointer { input -> Int in
            guard let base = input.baseAddress else { return 0 }
            return compression_decode_buffer(&output, size, base, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw ReaderError.notReadable }
        return Data(output)
    }

    /// The directory's end marker, found from the back because a comment can follow it.
    private func endRecord() throws -> Int {
        guard bytes.count >= 22 else { throw ReaderError.notReadable }
        var position = bytes.count - 22
        let earliest = max(0, position - 0xFFFF)
        while position >= earliest {
            if try u32(position) == 0x0605_4B50 { return position }
            position -= 1
        }
        throw ReaderError.notReadable
    }

    private func slice(_ start: Int, _ length: Int) throws -> ArraySlice<UInt8> {
        guard start >= 0, length >= 0, start <= bytes.count, length <= bytes.count - start else {
            throw ReaderError.notReadable
        }
        return bytes[start..<(start + length)]
    }

    private func u16(_ position: Int) throws -> Int {
        let part = try slice(position, 2)
        return Int(part[position]) | Int(part[position + 1]) << 8
    }

    private func u32(_ position: Int) throws -> Int {
        let part = try slice(position, 4)
        return (0..<4).reduce(0) { $0 | Int(part[position + $1]) << ($1 * 8) }
    }
}
