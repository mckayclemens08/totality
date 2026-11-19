import CryptoKit
import Foundation
import Sodium

public enum PairingError: Error, Equatable {
    /// The code isn't one Totality's website made.
    case badCode
    /// The browser's public key isn't the one in the QR code, so something between swapped it.
    case wrongBrowserKey
    case sealFailed
}

/// What a browser's QR code says. The iPhone reads it, checks the browser's key against `keyHash`, and seals
/// the content key to that browser. The web side is web/site/src/pairing/protocol.ts, and
/// docs/pairing-vectors.json holds vectors both sides' tests read.
public struct BrowserPairingRequest: Sendable, Equatable {
    public let slotID: UUID
    public let slotSecret: Data
    public let keyHash: String

    /// Nil for anything that isn't exactly `totality-pair/1/<slot id>/<secret>/<key hash>`.
    public init?(qr: String) {
        let parts = qr.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "totality-pair", parts[1] == "1",
              parts[2] == parts[2].lowercased(), let id = UUID(uuidString: parts[2]),
              let secret = Data(hex: parts[3], count: 32), Data(hex: parts[4], count: 32) != nil
        else { return nil }
        slotID = id
        slotSecret = secret
        keyHash = parts[4]
    }
}

public enum BrowserPairing {
    static let version: UInt8 = 1

    public struct Sealed: Sendable, Equatable {
        public let phonePublicKey: Data
        public let sealed: Data
    }

    public static func keyHash(browserPublicKey: Data) -> String {
        Data(SHA256.hash(data: Data("totality/pair-key/v1".utf8) + browserPublicKey)).hexString
    }

    /// The six digits that show on both screens, so the person can tell the iPhone read this screen's code.
    public static func code(slotID: UUID, browserPublicKey: Data) -> String {
        let hash = Array(SHA256.hash(data: Data("totality/pair-code/v1".utf8) + slotID.data + browserPublicKey))
        let number = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06d", number % 1_000_000)
    }

    /// Seals the content key to the browser. Refuses a browser key that doesn't match the QR code's hash.
    public static func seal(
        _ key: ContentRootKey, for request: BrowserPairingRequest, browserPublicKey: Data,
        phonePrivateKey: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws -> Sealed {
        guard browserPublicKey.count == 32 else { throw PairingError.badCode }
        guard keyHash(browserPublicKey: browserPublicKey) == request.keyHash else { throw PairingError.wrongBrowserKey }
        let browser = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: browserPublicKey)
        let phonePublic = phonePrivateKey.publicKey.rawRepresentation
        let session = try sessionKey(
            phonePrivateKey, browser, slotID: request.slotID, slotSecret: request.slotSecret,
            browserPublic: browserPublicKey, phonePublic: phonePublic
        )
        let sealed: (authenticatedCipherText: Bytes, nonce: Aead.XChaCha20Poly1305Ietf.Nonce)? =
            Sodium().aead.xchacha20poly1305ietf.encrypt(
                message: Bytes(key.bytes), secretKey: Bytes(session), additionalData: associatedData(request.slotID)
            )
        guard let sealed else { throw PairingError.sealFailed }
        return Sealed(
            phonePublicKey: phonePublic,
            sealed: Data([version]) + Data(sealed.nonce) + Data(sealed.authenticatedCipherText)
        )
    }

    /// The browser's half. The app never needs it, but the tests do, to prove the two sides agree.
    static func open(
        _ sealed: Data, slotID: UUID, slotSecret: Data, browserPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        phonePublicKey: Data
    ) throws -> Data {
        guard sealed.count == 1 + 24 + 32 + 16, sealed.first == version else { throw PairingError.sealFailed }
        let phone = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePublicKey)
        let session = try sessionKey(
            browserPrivateKey, phone, slotID: slotID, slotSecret: slotSecret,
            browserPublic: browserPrivateKey.publicKey.rawRepresentation, phonePublic: phonePublicKey
        )
        guard let plain = Sodium().aead.xchacha20poly1305ietf.decrypt(
            authenticatedCipherText: Bytes(sealed.dropFirst(25)), secretKey: Bytes(session),
            nonce: Bytes(sealed.dropFirst().prefix(24)), additionalData: associatedData(slotID)
        ) else { throw PairingError.sealFailed }
        return Data(plain)
    }

    private static func sessionKey(
        _ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Curve25519.KeyAgreement.PublicKey,
        slotID: UUID, slotSecret: Data, browserPublic: Data, phonePublic: Data
    ) throws -> Data {
        let shared = try mine.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
        let info = Data("totality/pair/v1".utf8) + slotID.data + browserPublic + phonePublic
        return hkdf(ikm: shared, salt: slotSecret, info: info, length: 32)
    }

    private static func associatedData(_ slotID: UUID) -> Bytes {
        Bytes("totality/pair/v1".utf8) + Bytes(slotID.data)
    }
}

extension Data {
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Lowercase hex of exactly `count` bytes, or nil.
    public init?(hex: String, count: Int) {
        guard hex.count == count * 2, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
