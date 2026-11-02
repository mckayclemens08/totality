import CryptoKit
import Foundation

/// The key mail is sealed to. It comes from the content key, so every device has it and the recovery
/// key restores it, and a password never touches it. The public half goes to the mail server.
public struct MailKey: Sendable {
    private static let info = Data("totality/mail/v1".utf8)
    private static let version: UInt8 = 1
    private static let encapsulatedCount = 32

    private let seed: Data

    public init(root: ContentRootKey) throws {
        try self.init(seed: hkdf(ikm: root.bytes, salt: Data(), info: Data("totality/mail-key/v1".utf8), length: 32))
    }

    init(seed: Data) throws {
        guard seed.count == 32 else { throw CryptoError.invalidKey }
        self.seed = seed
    }

    public func publicKey() throws -> Data {
        try privateKey().publicKey.rawRepresentation
    }

    private func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed) else {
            throw CryptoError.invalidKey
        }
        return key
    }

    /// Opens what the mail server stored. Layout: version (1) · HPKE encapsulated key (32) · ciphertext
    /// and tag. The mailbox and message IDs are authenticated, so a stored message can't be moved.
    public func open(_ sealed: Data, mailbox: UUID, message: UUID) throws -> Data {
        guard let first = sealed.first else { throw CryptoError.malformedCiphertext }
        guard first == Self.version else { throw CryptoError.unsupportedVersion(first) }
        guard sealed.count > 1 + Self.encapsulatedCount else { throw CryptoError.malformedCiphertext }
        let encapsulated = sealed.dropFirst().prefix(Self.encapsulatedCount)
        let body = sealed.dropFirst(1 + Self.encapsulatedCount)
        let privateKey = try privateKey()
        do {
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: Self.info,
                encapsulatedKey: Data(encapsulated)
            )
            return try recipient.open(Data(body), authenticating: Self.info + mailbox.data + message.data)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}
