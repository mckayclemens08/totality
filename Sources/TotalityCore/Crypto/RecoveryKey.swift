import Foundation
import Sodium

/// The key a user stores offline, in the Matrix recovery key format: 0x8B 0x01, 32 key bytes, and an
/// XOR parity byte, in Base58. Parity catches about 99.6% of single-character typos. The rest decode
/// to a different key, so whatever uses the key must still fail safely when it does not open anything.
public struct RecoveryKey: Sendable, Equatable {
    public static let byteCount = 32
    private static let prefix: [UInt8] = [0x8B, 0x01]
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw CryptoError.invalidKey }
        self.bytes = bytes
    }

    public static func generate() throws -> RecoveryKey {
        guard let random = Sodium().randomBytes.buf(length: byteCount) else { throw CryptoError.randomFailed }
        return try RecoveryKey(bytes: Data(random))
    }

    /// Accepts the key with or without the spaces it is displayed with.
    public init(encoded: String) throws {
        let text = encoded.filter { !$0.isWhitespace }
        guard let raw = Self.decodeBase58(text),
              raw.count == Self.prefix.count + Self.byteCount + 1,
              Array(raw.prefix(Self.prefix.count)) == Self.prefix,
              raw.reduce(0, ^) == 0 else { throw CryptoError.invalidRecoveryKey }
        bytes = Data(raw[Self.prefix.count..<(Self.prefix.count + Self.byteCount)])
    }

    /// Groups of four, for showing to a person.
    public var encoded: String {
        let body = Self.prefix + Array(bytes)
        let text = Self.encodeBase58(body + [body.reduce(0, ^)])
        return stride(from: 0, to: text.count, by: 4).map { start in
            let lower = text.index(text.startIndex, offsetBy: start)
            return String(text[lower..<(text.index(lower, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex)])
        }.joined(separator: " ")
    }

    private static func encodeBase58(_ input: [UInt8]) -> String {
        var digits: [UInt8] = []
        for byte in input {
            var carry = Int(byte)
            for index in digits.indices {
                carry += Int(digits[index]) << 8
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let zeros = input.prefix { $0 == 0 }.count
        let encoded = [UInt8](repeating: alphabet[0], count: zeros) + digits.reversed().map { alphabet[Int($0)] }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func decodeBase58(_ text: String) -> [UInt8]? {
        var output: [UInt8] = []
        for character in text.utf8 {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            var carry = value
            for index in output.indices {
                carry += Int(output[index]) * 58
                output[index] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                output.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }
        let zeros = text.utf8.prefix { $0 == alphabet[0] }.count
        return [UInt8](repeating: 0, count: zeros) + output.reversed()
    }
}
