import CryptoKit
import Foundation

/// Seals this person's own Sent copies for the mail server to keep. It's a symmetric key from the
/// content key, so only their devices can make one. That matters because the standard mail seal is to a
/// public key, which anyone can use: a Sent copy in that format could be planted by anyone holding a
/// stolen sign-in, and would look like the person's own words. A copy in this format can't.
///
/// Layout: version (2) · nonce (12) · ciphertext and tag (16). ChaCha20-Poly1305. The account and the
/// message's ID are authenticated, so a copy can't be moved to another account or another message.
public struct MailSentKey: Sendable {
    public static let version: UInt8 = 2
    private static let info = Data("totality/mail-sent/v1".utf8)
    private static let nonceCount = 12
    private static let tagCount = 16

    private let bytes: Data

    public init(root: ContentRootKey) {
        bytes = hkdf(ikm: root.bytes, salt: Data(), info: Self.info, length: 32)
    }

    private var key: SymmetricKey { SymmetricKey(data: bytes) }

    public func seal(_ plaintext: Data, account: UUID, message: UUID) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: Self.aad(account: account, message: message))
        return Data([Self.version]) + Data(box.nonce) + box.ciphertext + box.tag
    }

    public func open(_ sealed: Data, account: UUID, message: UUID) throws -> Data {
        guard let first = sealed.first else { throw CryptoError.malformedCiphertext }
        guard first == Self.version else { throw CryptoError.unsupportedVersion(first) }
        guard sealed.count > 1 + Self.nonceCount + Self.tagCount else { throw CryptoError.malformedCiphertext }
        do {
            let box = try ChaChaPoly.SealedBox(combined: Data(sealed.dropFirst()))
            return try ChaChaPoly.open(box, using: key, authenticating: Self.aad(account: account, message: message))
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    private static func aad(account: UUID, message: UUID) -> Data {
        info + account.data + message.data
    }
}
