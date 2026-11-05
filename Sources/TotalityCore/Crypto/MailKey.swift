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
        try open(sealed, info: Self.info, authenticating: Self.info + mailbox.data + message.data)
    }

    /// Seals in the standard outer format to this key's own public half, the way the server seals what
    /// arrives, so a Sent copy kept on the server opens with `open` like any other message.
    public func sealOwn(_ plaintext: Data, mailbox: UUID, message: UUID) throws -> Data {
        try Self.seal(plaintext, to: publicKey(), info: Self.info, authenticating: Self.info + mailbox.data + message.data)
    }

    // MARK: Mail between Totality accounts

    private static let directInfo = Data("totality/mail-direct/v1".utf8)

    /// What a sender's device seals for another Totality account, before the server wraps it in the
    /// standard outer seal. Who sent it, who it's for, and the message's ID are authenticated, so the
    /// server can't pass one person's sealed message off as another's, or deliver it to someone else.
    /// Names are compared lowercased, the way addresses are.
    public static func sealDirect(_ raw: Data, to recipientPublicKey: Data, from sender: String, recipient: String, message: UUID) throws -> Data {
        try seal(raw, to: recipientPublicKey, info: directInfo, authenticating: directAAD(sender: sender, recipient: recipient, message: message))
    }

    /// Opens what `sealDirect` made for this key. It fails unless the sender, the recipient, and the ID
    /// are exactly the ones it was sealed with.
    public func openDirect(_ sealed: Data, from sender: String, recipient: String, message: UUID) throws -> Data {
        try open(sealed, info: Self.directInfo, authenticating: Self.directAAD(sender: sender, recipient: recipient, message: message))
    }

    static func directAAD(sender: String, recipient: String, message: UUID) -> Data {
        directInfo + Data(sender.lowercased().utf8) + Data([0]) + Data(recipient.lowercased().utf8) + Data([0]) + message.data
    }

    // MARK: Sealing and opening

    private static func seal(_ plaintext: Data, to publicKey: Data, info: Data, authenticating aad: Data) throws -> Data {
        guard let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) else {
            throw CryptoError.invalidKey
        }
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        let body = try sender.seal(plaintext, authenticating: aad)
        return Data([version]) + sender.encapsulatedKey + body
    }

    private func open(_ sealed: Data, info: Data, authenticating aad: Data) throws -> Data {
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
                info: info,
                encapsulatedKey: Data(encapsulated)
            )
            return try recipient.open(Data(body), authenticating: aad)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}
