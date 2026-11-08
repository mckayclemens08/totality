import Foundation
import Testing
@testable import TotalityCore

@Suite struct ChunkedCipherTests {
    let key = try! ContentRootKey.generate().objectKey(for: UUID(), purpose: .photoVideo)
    let id = UUID()
    let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chunked-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private func sealed(_ plain: Data, chunk: Int = 1_000) throws -> URL {
        let input = folder.appendingPathComponent("plain-\(UUID().uuidString)")
        let output = folder.appendingPathComponent("sealed-\(UUID().uuidString)")
        try plain.write(to: input)
        try ChunkedCipher.seal(file: input, to: output, key: key, objectID: id, chunkSize: chunk)
        return output
    }

    private func plain(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    @Test func opensAnyRangeAndTheWholeFile() throws {
        let data = plain(10_500)
        let file = try sealed(data)
        #expect(try Data(contentsOf: file).count == ChunkedCipher.sealedLength(plain: 10_500, chunkSize: 1_000))
        #expect(try Data(contentsOf: file).range(of: data.prefix(32)) == nil)
        let reader = try ChunkedCipher.Reader(file: file, key: key, objectID: id)
        #expect(reader.plainLength == 10_500)
        #expect(try reader.read(0..<10_500) == data)
        #expect(try reader.read(999..<2_001) == data.subdata(in: 999..<2_001))
        #expect(try reader.read(10_400..<20_000) == data.subdata(in: 10_400..<10_500))
        let out = folder.appendingPathComponent("out")
        try reader.copyPlain(to: out)
        #expect(try Data(contentsOf: out) == data)
    }

    @Test func aFileCutShortOrAddedToIsRefusedAtOnce() throws {
        let file = try sealed(plain(3_000))
        let whole = try Data(contentsOf: file)
        let short = folder.appendingPathComponent("short")
        try whole.dropLast(1_040).write(to: short)
        #expect(throws: CryptoError.malformedCiphertext) { try ChunkedCipher.Reader(file: short, key: key, objectID: id) }
        let long = folder.appendingPathComponent("long")
        try (whole + Data(count: 10)).write(to: long)
        #expect(throws: CryptoError.malformedCiphertext) { try ChunkedCipher.Reader(file: long, key: key, objectID: id) }
    }

    @Test func swappedChunksAnotherFilesIDOrAnotherKeyNeverOpen() throws {
        let file = try sealed(plain(3_000))
        var bytes = [UInt8](try Data(contentsOf: file))
        let stride = 1_000 + 40
        let first = Array(bytes[13..<13 + stride])
        bytes.replaceSubrange(13..<13 + stride, with: bytes[13 + stride..<13 + 2 * stride])
        bytes.replaceSubrange(13 + stride..<13 + 2 * stride, with: first)
        let swapped = folder.appendingPathComponent("swapped")
        try Data(bytes).write(to: swapped)
        #expect(throws: CryptoError.authenticationFailed) { try ChunkedCipher.Reader(file: swapped, key: key, objectID: id).read(0..<10) }
        #expect(throws: CryptoError.authenticationFailed) { try ChunkedCipher.Reader(file: file, key: key, objectID: UUID()).read(0..<10) }
        let other = try ContentRootKey.generate().objectKey(for: id, purpose: .photoVideo)
        #expect(throws: CryptoError.authenticationFailed) { try ChunkedCipher.Reader(file: file, key: other, objectID: id).read(0..<10) }
    }

    @Test func aChangedHeaderNeverOpens() throws {
        let file = try sealed(plain(2_500))
        var bytes = [UInt8](try Data(contentsOf: file))
        // A smaller chunk size that still matches the file's length can't be made, and a changed length
        // no longer matches the file.
        bytes[12] ^= 0x01
        let changed = folder.appendingPathComponent("changed")
        try Data(bytes).write(to: changed)
        #expect(throws: CryptoError.malformedCiphertext) { try ChunkedCipher.Reader(file: changed, key: key, objectID: id) }
        #expect(throws: CryptoError.malformedCiphertext) { try ChunkedCipher.Header(Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])) }
    }
}
