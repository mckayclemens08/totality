import CryptoKit
import Foundation
import Sodium

/// What other users see, matching the `identity_keys` table. The self-signature proves the two keys
/// belong together. It does not prove who owns them: that needs contact verification, so a contact
/// stays Unverified until then.
public struct IdentityBundle: Sendable, Equatable, Codable {
    public let signingPublicKey: Data
    public let exchangePublicKey: Data
    public let selfSignature: Data

    public init(signingPublicKey: Data, exchangePublicKey: Data, selfSignature: Data) {
        self.signingPublicKey = signingPublicKey
        self.exchangePublicKey = exchangePublicKey
        self.selfSignature = selfSignature
    }

    static func signedBytes(signing: Data, exchange: Data) -> Data {
        Data("totality/identity/v1".utf8) + signing + exchange
    }

    public func verify() throws {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey),
              key.isValidSignature(selfSignature, for: Self.signedBytes(signing: signingPublicKey, exchange: exchangePublicKey))
        else { throw CryptoError.invalidSignature }
    }
}

/// A user's long-term private keys. They stay on devices and in the key backup.
public struct IdentityKeys: Sendable {
    private static let partCount = 32
    private let signingSecret: Data
    private let exchangeSecret: Data
    private let exchangePublic: Data

    public static func generate() throws -> IdentityKeys {
        guard let pair = Sodium().box.keyPair() else { throw CryptoError.randomFailed }
        return IdentityKeys(
            signingSecret: Curve25519.Signing.PrivateKey().rawRepresentation,
            exchangeSecret: Data(pair.secretKey),
            exchangePublic: Data(pair.publicKey)
        )
    }

    private init(signingSecret: Data, exchangeSecret: Data, exchangePublic: Data) {
        self.signingSecret = signingSecret
        self.exchangeSecret = exchangeSecret
        self.exchangePublic = exchangePublic
    }

    /// Restores keys from `secretData`, as read back from a `KeyStore`.
    public init(secretData: Data) throws {
        guard secretData.count == Self.partCount * 3 else { throw CryptoError.invalidKey }
        let bytes = Data(secretData)
        self.init(
            signingSecret: bytes.subdata(in: 0..<Self.partCount),
            exchangeSecret: bytes.subdata(in: Self.partCount..<(Self.partCount * 2)),
            exchangePublic: bytes.subdata(in: (Self.partCount * 2)..<(Self.partCount * 3))
        )
    }

    /// For a `KeyStore` only. This is the user's private identity and must never leave the device
    /// except inside the encrypted key backup.
    public var secretData: Data {
        signingSecret + exchangeSecret + exchangePublic
    }

    public func bundle() throws -> IdentityBundle {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: signingSecret)
        let signingPublic = signing.publicKey.rawRepresentation
        let signature = try signing.signature(for: IdentityBundle.signedBytes(signing: signingPublic, exchange: exchangePublic))
        return IdentityBundle(signingPublicKey: signingPublic, exchangePublicKey: exchangePublic, selfSignature: signature)
    }

    /// Opens a key another user sealed to this identity.
    public func open(_ wrapped: Data) throws -> ObjectKey {
        guard let bytes = Sodium().box.open(
            anonymousCipherText: Bytes(wrapped),
            recipientPublicKey: Bytes(exchangePublic),
            recipientSecretKey: Bytes(exchangeSecret)
        ) else { throw CryptoError.authenticationFailed }
        return try ObjectKey(bytes: Data(bytes))
    }
}

extension ObjectKey {
    /// Seals this key to one recipient for `content_shares.wrapped_key`. Refuses a bundle whose
    /// self-signature does not check out.
    public func wrapped(for recipient: IdentityBundle) throws -> Data {
        try recipient.verify()
        guard let sealed = Sodium().box.seal(message: Bytes(bytes), recipientPublicKey: Bytes(recipient.exchangePublicKey)) else {
            throw CryptoError.invalidKey
        }
        return Data(sealed)
    }
}
