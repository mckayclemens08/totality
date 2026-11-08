import Foundation
import Sodium

/// XChaCha20-Poly1305 for a file too big to hold in memory, like a video. The file is sealed in chunks of
/// 1 MiB, so it can be sealed, uploaded, and played a piece at a time, and a player can jump to any point
/// without opening the rest.
///
/// Layout: version (1) · chunk size (4) · plaintext length (8), then each chunk as nonce (24) · ciphertext
/// and tag. Every chunk's associated data names the object, the chunk's place, the chunk size and the
/// whole length, so a server can't swap chunks between files or places, cut the file short, or add to it.
public enum ChunkedCipher {
    static let version: UInt8 = 2
    public static let chunkSize = 1 << 20
    static let headerCount = 13
    private static let nonceCount = 24
    private static let tagCount = 16
    static let overhead = nonceCount + tagCount

    /// The sealed size of a file of `plainLength` bytes.
    public static func sealedLength(plain plainLength: Int, chunkSize: Int = chunkSize) -> Int {
        let chunks = (plainLength + chunkSize - 1) / chunkSize
        return headerCount + plainLength + chunks * overhead
    }

    /// Seals `input` into `output`, a chunk at a time. `output` is replaced.
    public static func seal(file input: URL, to output: URL, key: ObjectKey, objectID: UUID, chunkSize: Int = chunkSize) throws {
        let length = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard length > 0, chunkSize > 0 else { throw CryptoError.malformedCiphertext }
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 0)
        let header = Header(chunkSize: chunkSize, plainLength: length)
        try writer.write(contentsOf: header.bytes)
        var index = 0
        var done = 0
        while done < length {
            let count = min(chunkSize, length - done)
            guard let plain = try reader.read(upToCount: count), plain.count == count else { throw CryptoError.malformedCiphertext }
            try writer.write(contentsOf: try sealChunk(plain, key: key, objectID: objectID, index: index, header: header))
            done += count
            index += 1
        }
    }

    public enum Reseal: Equatable {
        case moved, alreadyMoved, unreadable
    }

    /// Moves a sealed file from one key to another, a chunk at a time, through `temporary`. The new copy
    /// is read back in full and compared before it replaces the old, so a crash at any point leaves one
    /// whole copy under one of the two keys, and running it again finishes the job.
    public static func reseal(_ file: URL, through temporary: URL, from old: ObjectKey, to new: ObjectKey, objectID: UUID) throws -> Reseal {
        if let reader = try? Reader(file: file, key: new, objectID: objectID), (try? reader.verifyAll()) != nil { return .alreadyMoved }
        guard let source = try? Reader(file: file, key: old, objectID: objectID), (try? source.verifyAll()) != nil else { return .unreadable }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        do {
            let writer = try FileHandle(forWritingTo: temporary)
            defer { try? writer.close() }
            try writer.truncate(atOffset: 0)
            let header = Header(chunkSize: source.chunkSize, plainLength: source.plainLength)
            try writer.write(contentsOf: header.bytes)
            for index in 0..<source.chunkCount {
                try writer.write(contentsOf: try sealChunk(try source.chunk(index), key: new, objectID: objectID, index: index, header: header))
            }
            try writer.synchronize()
            let written = try Reader(file: temporary, key: new, objectID: objectID)
            for index in 0..<source.chunkCount where try written.chunk(index) != source.chunk(index) {
                throw CryptoError.authenticationFailed
            }
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            return .moved
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func sealChunk(_ plain: Data, key: ObjectKey, objectID: UUID, index: Int, header: Header) throws -> Data {
        let sealed: (authenticatedCipherText: Bytes, nonce: Aead.XChaCha20Poly1305Ietf.Nonce)? = Sodium().aead.xchacha20poly1305ietf.encrypt(
            message: Bytes(plain), secretKey: Bytes(key.bytes), additionalData: associatedData(objectID, index: index, header: header)
        )
        guard let sealed else { throw CryptoError.authenticationFailed }
        return Data(sealed.nonce) + Data(sealed.authenticatedCipherText)
    }

    struct Header: Equatable {
        let chunkSize: Int
        let plainLength: Int

        var bytes: Data {
            var data = Data([ChunkedCipher.version])
            data += withUnsafeBytes(of: UInt32(chunkSize).bigEndian) { Data($0) }
            data += withUnsafeBytes(of: UInt64(plainLength).bigEndian) { Data($0) }
            return data
        }

        init(chunkSize: Int, plainLength: Int) {
            self.chunkSize = chunkSize
            self.plainLength = plainLength
        }

        init(_ data: Data) throws {
            guard data.count == ChunkedCipher.headerCount else { throw CryptoError.malformedCiphertext }
            let bytes = [UInt8](data)
            guard bytes[0] == ChunkedCipher.version else { throw CryptoError.unsupportedVersion(bytes[0]) }
            let size = bytes[1..<5].reduce(0) { $0 << 8 | Int($1) }
            let length = bytes[5..<13].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            // Sizes no real file has are refused, so nothing here can be made to allocate without limit.
            guard size > 0, size <= 16 << 20, length > 0, length <= UInt64(1) << 40 else { throw CryptoError.malformedCiphertext }
            chunkSize = size
            plainLength = Int(length)
        }
    }

    private static func associatedData(_ objectID: UUID, index: Int, header: Header) -> Bytes {
        Bytes("totality/chunk/v1".utf8) + Bytes(objectID.data) + Bytes(header.bytes)
            + withUnsafeBytes(of: UInt64(index).bigEndian) { Bytes($0) }
    }

    /// Opens a sealed file a range at a time. It checks the file is exactly as long as its header says
    /// before anything is read, so a file cut short or added to is refused at once.
    public final class Reader: @unchecked Sendable {
        public let plainLength: Int
        private let header: Header
        private let handle: FileHandle
        private let key: ObjectKey
        private let objectID: UUID
        private let lock = NSLock()

        public init(file: URL, key: ObjectKey, objectID: UUID) throws {
            handle = try FileHandle(forReadingFrom: file)
            do {
                guard let first = try handle.read(upToCount: ChunkedCipher.headerCount) else { throw CryptoError.malformedCiphertext }
                header = try Header(first)
                // From the open file itself, so a file swapped after opening can't pass.
                let size = Int(try handle.seekToEnd())
                guard size == ChunkedCipher.sealedLength(plain: header.plainLength, chunkSize: header.chunkSize) else {
                    throw CryptoError.malformedCiphertext
                }
            } catch {
                try? handle.close()
                throw error
            }
            plainLength = header.plainLength
            self.key = key
            self.objectID = objectID
        }

        deinit {
            try? handle.close()
        }

        var chunkSize: Int { header.chunkSize }
        var chunkCount: Int { (plainLength + header.chunkSize - 1) / header.chunkSize }

        func chunk(_ index: Int) throws -> Data {
            try open(index)
        }

        /// Opens every chunk once, so a file damaged anywhere is refused before it's kept or played.
        public func verifyAll() throws {
            for index in 0..<chunkCount { _ = try open(index) }
        }

        /// The plaintext in `range`, which is clamped to the file.
        public func read(_ range: Range<Int>) throws -> Data {
            let range = max(0, range.lowerBound)..<min(plainLength, range.upperBound)
            guard !range.isEmpty else { return Data() }
            var result = Data(capacity: range.count)
            var chunk = range.lowerBound / header.chunkSize
            while chunk * header.chunkSize < range.upperBound {
                let plain = try open(chunk)
                let start = chunk * header.chunkSize
                let from = max(range.lowerBound - start, 0)
                let to = min(range.upperBound - start, plain.count)
                result += plain[plain.startIndex + from..<plain.startIndex + to]
                chunk += 1
            }
            return result
        }

        /// Writes the whole plaintext to `output`, a chunk at a time.
        public func copyPlain(to output: URL) throws {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            try writer.truncate(atOffset: 0)
            let chunks = (plainLength + header.chunkSize - 1) / header.chunkSize
            for chunk in 0..<chunks { try writer.write(contentsOf: try open(chunk)) }
        }

        private func open(_ index: Int) throws -> Data {
            let start = index * header.chunkSize
            let count = min(header.chunkSize, plainLength - start)
            let offset = ChunkedCipher.headerCount + index * (header.chunkSize + ChunkedCipher.overhead)
            let sealed: Data = try lock.withLock {
                try handle.seek(toOffset: UInt64(offset))
                guard let data = try handle.read(upToCount: count + ChunkedCipher.overhead), data.count == count + ChunkedCipher.overhead else {
                    throw CryptoError.malformedCiphertext
                }
                return data
            }
            let aead = Sodium().aead.xchacha20poly1305ietf
            guard let plain = aead.decrypt(
                authenticatedCipherText: Bytes(sealed.dropFirst(ChunkedCipher.nonceCount)),
                secretKey: Bytes(key.bytes),
                nonce: Bytes(sealed.prefix(ChunkedCipher.nonceCount)),
                additionalData: ChunkedCipher.associatedData(objectID, index: index, header: header)
            ) else { throw CryptoError.authenticationFailed }
            return Data(plain)
        }
    }
}
