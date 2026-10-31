import CommonCrypto
import CryptoKit
import Foundation
import Sodium

/// One value locked in Matrix secret storage's format, `m.secret_storage.v1.aes-hmac-sha2`:
/// AES-256-CTR and HMAC-SHA-256, under keys derived from the recovery key and the secret's name.
public struct LockedSecret: Codable, Sendable, Equatable {
    public let iv: String
    public let ciphertext: String
    public let mac: String

    public init(iv: String, ciphertext: String, mac: String) {
        self.iv = iv
        self.ciphertext = ciphertext
        self.mac = mac
    }

    static func lock(_ plaintext: Data, with key: Data, name: String) throws -> LockedSecret {
        guard var iv = Sodium().randomBytes.buf(length: 16) else { throw CryptoError.randomFailed }
        // Clearing this bit leaves room for the counter, as the Matrix spec requires.
        iv[8] &= 0x7F
        return try lock(plaintext, with: key, name: name, iv: Data(iv))
    }

    static func lock(_ plaintext: Data, with key: Data, name: String, iv: Data) throws -> LockedSecret {
        let keys = derive(key, name: name)
        let ciphertext = try aesCTR(plaintext, key: keys.aes, iv: iv)
        let mac = HMAC<SHA256>.authenticationCode(for: ciphertext, using: SymmetricKey(data: keys.mac))
        return LockedSecret(
            iv: iv.base64EncodedString(), ciphertext: ciphertext.base64EncodedString(),
            mac: Data(mac).base64EncodedString()
        )
    }

    /// The MAC is checked first, so a wrong key fails here and never produces garbage.
    func open(with key: Data, name: String) throws -> Data {
        guard let iv = Data(base64Encoded: iv), iv.count == 16,
              let ciphertext = Data(base64Encoded: ciphertext),
              let mac = Data(base64Encoded: mac)
        else { throw CryptoError.malformedCiphertext }
        let keys = derive(key, name: name)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: ciphertext, using: SymmetricKey(data: keys.mac)) else {
            throw CryptoError.authenticationFailed
        }
        return try aesCTR(ciphertext, key: keys.aes, iv: iv)
    }

    private func derive(_ key: Data, name: String) -> (aes: Data, mac: Data) {
        Self.derive(key, name: name)
    }

    private static func derive(_ key: Data, name: String) -> (aes: Data, mac: Data) {
        let okm = hkdf(ikm: key, salt: Data(count: 32), info: Data(name.utf8), length: 64)
        return (okm.prefix(32), okm.suffix(32))
    }
}

private func aesCTR(_ input: Data, key: Data, iv: Data) throws -> Data {
    var cryptor: CCCryptorRef?
    let created = key.withUnsafeBytes { keyBytes in
        iv.withUnsafeBytes { ivBytes in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0,
                CCModeOptions(kCCModeOptionCTR_BE), &cryptor
            )
        }
    }
    guard created == CCCryptorStatus(kCCSuccess), let cryptor else { throw CryptoError.authenticationFailed }
    defer { CCCryptorRelease(cryptor) }
    var output = Data(count: input.count)
    var written = 0
    let status = output.withUnsafeMutableBytes { outputBytes in
        input.withUnsafeBytes { inputBytes in
            CCCryptorUpdate(cryptor, inputBytes.baseAddress, input.count, outputBytes.baseAddress, input.count, &written)
        }
    }
    guard status == CCCryptorStatus(kCCSuccess), written == input.count else { throw CryptoError.authenticationFailed }
    return output
}

/// The content root key, locked by the recovery key. Everything here is safe for a server to hold: it
/// opens only with a key that never leaves the person's hands.
public struct KeyBackup: Codable, Sendable, Equatable {
    public static let secretName = "app.totality.content_root_key"
    public static let algorithm = "m.secret_storage.v1.aes-hmac-sha2"

    public let keyID: String
    /// Matrix's way to test a recovery key: 32 zero bytes locked under the empty name.
    public let check: LockedSecret
    public let secret: LockedSecret

    public init(keyID: String, check: LockedSecret, secret: LockedSecret) {
        self.keyID = keyID
        self.check = check
        self.secret = secret
    }

    public static func seal(_ rootKey: ContentRootKey, with recovery: RecoveryKey) throws -> KeyBackup {
        guard let id = Sodium().randomBytes.buf(length: 16) else { throw CryptoError.randomFailed }
        return KeyBackup(
            keyID: Data(id).map { String(format: "%02x", $0) }.joined(),
            check: try .lock(Data(count: 32), with: recovery.bytes, name: ""),
            secret: try .lock(Data(rootKey.bytes.unpaddedBase64.utf8), with: recovery.bytes, name: secretName)
        )
    }

    /// Matrix stores only the check's IV and MAC, so the test is to remake it and compare.
    public func opens(with recovery: RecoveryKey) -> Bool {
        guard let iv = Data(base64Encoded: check.iv) else { return false }
        return (try? LockedSecret.lock(Data(count: 32), with: recovery.bytes, name: "", iv: iv))?.mac == check.mac
    }

    public func open(with recovery: RecoveryKey) throws -> ContentRootKey {
        let encoded = try secret.open(with: recovery.bytes, name: Self.secretName)
        guard let text = String(data: encoded, encoding: .utf8), let bytes = Data(unpaddedBase64: text) else {
            throw CryptoError.malformedCiphertext
        }
        return try ContentRootKey(bytes: bytes)
    }
}

extension Data {
    var unpaddedBase64: String {
        base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    init?(unpaddedBase64 text: String) {
        self.init(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
}
