import CryptoKit
import Foundation
import Sodium

public enum CryptoError: Error, Equatable {
    case invalidKey
    case malformedCiphertext
    case unsupportedVersion(UInt8)
    case authenticationFailed
    case randomFailed
    case invalidRecoveryKey
    case invalidSignature
}

/// What a derived key is for. Each purpose gets its own key, so a metadata key can never open a blob.
public enum KeyPurpose: String, Sendable, Hashable {
    case content
    case metadata
    /// Calendar events. Their own purpose means one module's blob can never open as another's.
    case event
    /// Web bookmarks, which sync.
    case bookmark
    /// Web history, open tabs, and settings, which stay on the device.
    case browsing
    /// A photo's original file, its thumbnail, and its details (issue 54). Each part has its own key, so
    /// a server can't pass one off as another.
    case photo
    case photoThumbnail = "photo-thumbnail"
    case photoDetails = "photo-details"
    /// A photo album's name.
    case photoAlbum = "photo-album"
    /// A video, or a Live Photo's moving part, sealed in chunks with `ChunkedCipher`.
    case photoVideo = "photo-video"
    /// What's kept on a device of a connected Google account's calendars (issue 76). It never syncs.
    case googleCalendar = "google-calendar"
    /// What iPhone sync has already brought in, and how it's set, kept on the device only (issue 77).
    case photoSync = "photo-sync"
}

/// The root of a user's private content. Lives on devices and in the key backup, never on a server.
public struct ContentRootKey: Sendable, Equatable {
    public static let byteCount = 32
    let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw CryptoError.invalidKey }
        self.bytes = bytes
    }

    public static func generate() throws -> ContentRootKey {
        guard let random = Sodium().randomBytes.buf(length: byteCount) else { throw CryptoError.randomFailed }
        return try ContentRootKey(bytes: Data(random))
    }

    /// What locks this account's Messages key backup on the Matrix server (its secret storage). It comes
    /// from this key, which only the recovery key restores on a new device, and never from the password,
    /// which the account server receives. Working backwards from it to this key isn't possible.
    public func matrixRecoverySecret() -> String {
        hkdf(ikm: bytes, salt: Data(), info: Data("totality/matrix-recovery/v1".utf8), length: 32).base64EncodedString()
    }

    /// The key for one object. Sharing it never reveals the root or any other object's key.
    /// The same text gives the same ID on every device with this key, and nobody else can work it out.
    public func derivedID(from text: String) -> UUID {
        var id = Array(hkdf(ikm: bytes, salt: Data(), info: Data("totality/derived-id/v1".utf8) + Data(text.utf8), length: 16))
        id[6] = (id[6] & 0x0F) | 0x40
        id[8] = (id[8] & 0x3F) | 0x80
        return id.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    public func objectKey(for objectID: UUID, purpose: KeyPurpose) -> ObjectKey {
        let info = Data("totality/\(purpose.rawValue)/v1".utf8) + objectID.data
        return ObjectKey(unchecked: hkdf(ikm: bytes, salt: Data(), info: info, length: Self.byteCount))
    }
}

public struct ObjectKey: Sendable, Equatable {
    public static let byteCount = 32
    let bytes: Data

    init(unchecked bytes: Data) {
        self.bytes = bytes
    }

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw CryptoError.invalidKey }
        self.bytes = bytes
    }

    /// A random key tied to no root key, for a sealed copy that is handed to someone else.
    public static func generate() throws -> ObjectKey {
        guard let random = Sodium().randomBytes.buf(length: byteCount) else { throw CryptoError.randomFailed }
        return ObjectKey(unchecked: Data(random))
    }
}

/// XChaCha20-Poly1305 for one blob. Layout: version (1) · nonce (24) · ciphertext and tag.
/// The object ID is authenticated, so the server cannot swap one user's blobs between objects.
public enum ContentCipher {
    static let version: UInt8 = 1
    private static let nonceCount = 24

    public static func seal(_ plaintext: Data, key: ObjectKey, objectID: UUID) throws -> Data {
        let aead = Sodium().aead.xchacha20poly1305ietf
        let sealed: (authenticatedCipherText: Bytes, nonce: Aead.XChaCha20Poly1305Ietf.Nonce)? = aead.encrypt(
            message: Bytes(plaintext),
            secretKey: Bytes(key.bytes),
            additionalData: associatedData(objectID)
        )
        guard let sealed else { throw CryptoError.authenticationFailed }
        return Data([version]) + Data(sealed.nonce) + Data(sealed.authenticatedCipherText)
    }

    public static func open(_ sealed: Data, key: ObjectKey, objectID: UUID) throws -> Data {
        guard let first = sealed.first else { throw CryptoError.malformedCiphertext }
        guard first == version else { throw CryptoError.unsupportedVersion(first) }
        let aead = Sodium().aead.xchacha20poly1305ietf
        guard sealed.count >= 1 + nonceCount + aead.ABytes else { throw CryptoError.malformedCiphertext }
        let nonce = sealed.dropFirst().prefix(nonceCount)
        let body = sealed.dropFirst(1 + nonceCount)
        guard let plaintext = aead.decrypt(
            authenticatedCipherText: Bytes(body),
            secretKey: Bytes(key.bytes),
            nonce: Bytes(nonce),
            additionalData: associatedData(objectID)
        ) else { throw CryptoError.authenticationFailed }
        return Data(plaintext)
    }

    private static func associatedData(_ objectID: UUID) -> Bytes {
        Bytes("totality/blob/v1".utf8) + Bytes(objectID.data)
    }
}

func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
    HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: ikm),
        salt: salt,
        info: info,
        outputByteCount: length
    ).withUnsafeBytes { Data($0) }
}

extension UUID {
    var data: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
