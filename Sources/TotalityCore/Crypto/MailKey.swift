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
    ///
    /// Anyone can seal to a public key, the server included, so nothing opened here says who wrote it.
    /// A Sent copy has its own format, `MailSentKey`, which only this person's devices can make.
    public func open(_ sealed: Data, mailbox: UUID, message: UUID) throws -> Data {
        try open(sealed, info: Self.info, authenticating: Self.info + mailbox.data + message.data, sender: nil)
    }

    // MARK: Mail between Totality accounts

    private static let directInfo = Data("totality/mail-direct/v2".utf8)

    /// What this account's device seals for another Totality account, before the server wraps it in the
    /// standard outer seal. It's HPKE in auth mode, sealed with this key's private half, so only a device
    /// holding it can make one: the server can't mint a message from anyone. Who sent it, who it's for,
    /// and the message's ID are authenticated too, so the server can't pass one person's sealed message
    /// off as another's, or deliver it to someone else. Names are compared lowercased, the way addresses are.
    public func sealDirect(_ raw: Data, to recipientPublicKey: Data, from sender: String, recipient: String, message: UUID) throws -> Data {
        try Self.seal(
            raw, to: recipientPublicKey, info: Self.directInfo,
            authenticating: Self.directAAD(sender: sender, recipient: recipient, message: message), sender: privateKey()
        )
    }

    /// Opens what `sealDirect` made for this key. It fails unless the sender's public key, the sender's
    /// name, the recipient, and the ID are exactly the ones it was sealed with. The key has to come from
    /// somewhere other than the message, and the caller decides how far to trust it.
    public func openDirect(_ sealed: Data, senderKey: Data, from sender: String, recipient: String, message: UUID) throws -> Data {
        guard let senderKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderKey) else { throw CryptoError.invalidKey }
        return try open(
            sealed, info: Self.directInfo, authenticating: Self.directAAD(sender: sender, recipient: recipient, message: message),
            sender: senderKey
        )
    }

    static func directAAD(sender: String, recipient: String, message: UUID) -> Data {
        directInfo + Data(sender.lowercased().utf8) + Data([0]) + Data(recipient.lowercased().utf8) + Data([0]) + message.data
    }

    // MARK: Sealing and opening

    /// `sender` set means auth mode, which proves the sealer held that private key.
    static func seal(
        _ plaintext: Data, to publicKey: Data, info: Data, authenticating aad: Data, sender authentication: Curve25519.KeyAgreement.PrivateKey?
    ) throws -> Data {
        guard let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) else {
            throw CryptoError.invalidKey
        }
        var sender = if let authentication {
            try HPKE.Sender(recipientKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info, authenticatedBy: authentication)
        } else {
            try HPKE.Sender(recipientKey: recipient, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        }
        let body = try sender.seal(plaintext, authenticating: aad)
        return Data([version]) + sender.encapsulatedKey + body
    }

    /// `sender` set means auth mode: it opens only what that key's private half sealed.
    private func open(_ sealed: Data, info: Data, authenticating aad: Data, sender: Curve25519.KeyAgreement.PublicKey?) throws -> Data {
        guard let first = sealed.first else { throw CryptoError.malformedCiphertext }
        guard first == Self.version else { throw CryptoError.unsupportedVersion(first) }
        guard sealed.count > 1 + Self.encapsulatedCount else { throw CryptoError.malformedCiphertext }
        let encapsulated = sealed.dropFirst().prefix(Self.encapsulatedCount)
        let body = sealed.dropFirst(1 + Self.encapsulatedCount)
        let privateKey = try privateKey()
        do {
            var recipient = if let sender {
                try HPKE.Recipient(
                    privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info,
                    encapsulatedKey: Data(encapsulated), authenticatedBy: sender
                )
            } else {
                try HPKE.Recipient(
                    privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info, encapsulatedKey: Data(encapsulated)
                )
            }
            return try recipient.open(Data(body), authenticating: aad)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}
