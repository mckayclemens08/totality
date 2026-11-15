import Foundation

/// Writes a zip in memory, for a Word file. Entries are stored, not compressed: Word reads either, and
/// storing needs nothing but a checksum.
struct ZipWriter {
    private var data = Data()
    private var directory = Data()
    private var count = 0

    /// A fixed time, 1 January 2001, so the same doc always exports to the same bytes.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = UInt16((2001 - 1980) << 9 | 1 << 5 | 1)

    mutating func add(_ name: String, _ contents: Data) {
        let nameBytes = Data(name.utf8)
        let crc = Self.crc32(contents)
        let offset = UInt32(data.count)
        var local = Data()
        local.append(le32: 0x0403_4B50)
        local.append(le16: 20)          // version needed
        local.append(le16: 0x0800)      // names are UTF-8
        local.append(le16: 0)           // stored
        local.append(le16: Self.dosTime)
        local.append(le16: Self.dosDate)
        local.append(le32: crc)
        local.append(le32: UInt32(contents.count))
        local.append(le32: UInt32(contents.count))
        local.append(le16: UInt16(nameBytes.count))
        local.append(le16: 0)
        local.append(nameBytes)
        data.append(local)
        data.append(contents)

        directory.append(le32: 0x0201_4B50)
        directory.append(le16: 20)      // made by
        directory.append(le16: 20)
        directory.append(le16: 0x0800)
        directory.append(le16: 0)
        directory.append(le16: Self.dosTime)
        directory.append(le16: Self.dosDate)
        directory.append(le32: crc)
        directory.append(le32: UInt32(contents.count))
        directory.append(le32: UInt32(contents.count))
        directory.append(le16: UInt16(nameBytes.count))
        directory.append(le16: 0)       // extra
        directory.append(le16: 0)       // comment
        directory.append(le16: 0)       // disk
        directory.append(le16: 0)       // internal attributes
        directory.append(le32: 0)       // external attributes
        directory.append(le32: offset)
        directory.append(nameBytes)
        count += 1
    }

    func finished() -> Data {
        var result = data
        let start = UInt32(result.count)
        result.append(directory)
        result.append(le32: 0x0605_4B50)
        result.append(le16: 0)
        result.append(le16: 0)
        result.append(le16: UInt16(count))
        result.append(le16: UInt16(count))
        result.append(le32: UInt32(directory.count))
        result.append(le32: start)
        result.append(le16: 0)
        return result
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(le32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}
