import Foundation
import Sodium
import Testing
@testable import TotalityCore

private func hex(_ text: String) -> Data {
    let digits = Array(text.filter { !$0.isWhitespace })
    return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...($0 + 1)]), radix: 16)! })
}

@Suite("Known-answer vectors")
struct KnownAnswerTests {
    @Test("XChaCha20-Poly1305 decrypts the IETF draft vector")
    func xchacha() throws {
        let plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
        let ciphertext = hex("""
            bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb
            731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452
            2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9
            21f9664c97637da9768812f615c68b13b52e c0875924c1c7987947deafd8780acf49
            """)
        let opened = Sodium().aead.xchacha20poly1305ietf.decrypt(
            authenticatedCipherText: Bytes(ciphertext),
            secretKey: Bytes(0x80...0x9F),
            nonce: Bytes(0x40...0x57),
            additionalData: Bytes(hex("50515253c0c1c2c3c4c5c6c7"))
        )
        #expect(opened.map { String(decoding: $0, as: UTF8.self) } == plaintext)
    }

    @Test("HKDF-SHA256 matches RFC 5869 case 1")
    func hkdfVector() {
        let output = hkdf(
            ikm: Data(repeating: 0x0B, count: 22),
            salt: hex("000102030405060708090a0b0c"),
            info: hex("f0f1f2f3f4f5f6f7f8f9"),
            length: 42
        )
        #expect(output == hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))
    }

    @Test("Recovery key matches an independently computed encoding")
    func recoveryKeyVector() throws {
        let key = try RecoveryKey(bytes: Data(0..<32))
        #expect(key.encoded == "EsSz ykH7 LCZx 7Cae cmKD wcmY JRXi Ybtu 8iQ3 t8Ez nRwK pUY1")
    }
}

@Suite("Content encryption")
struct ContentCipherTests {
    let root = try! ContentRootKey.generate()
    let id = UUID()
    let message = Data("Second-quarter budget notes".utf8)

    @Test func roundTrip() throws {
        let key = root.objectKey(for: id, purpose: .content)
        let sealed = try ContentCipher.seal(message, key: key, objectID: id)
        #expect(try ContentCipher.open(sealed, key: key, objectID: id) == message)
    }

    @Test func emptyFileRoundTrips() throws {
        let key = root.objectKey(for: id, purpose: .content)
        let sealed = try ContentCipher.seal(Data(), key: key, objectID: id)
        #expect(try ContentCipher.open(sealed, key: key, objectID: id).isEmpty)
    }

    @Test("Ciphertext never contains the plaintext, and repeats never match")
    func ciphertextIsOpaque() throws {
        let key = root.objectKey(for: id, purpose: .content)
        let first = try ContentCipher.seal(message, key: key, objectID: id)
        let second = try ContentCipher.seal(message, key: key, objectID: id)
        #expect(first != second)
        #expect(first.range(of: message) == nil)
    }

    @Test("Every flipped byte is rejected")
    func tamperingIsRejected() throws {
        let key = root.objectKey(for: id, purpose: .content)
        let sealed = try ContentCipher.seal(message, key: key, objectID: id)
        for index in sealed.indices {
            var bad = sealed
            bad[index] ^= 0x01
            #expect(throws: (any Error).self) { try ContentCipher.open(bad, key: key, objectID: id) }
        }
    }

    @Test("A blob moved to another object is rejected, even with the right key")
    func swappedBlobIsRejected() throws {
        let key = root.objectKey(for: id, purpose: .content)
        let sealed = try ContentCipher.seal(message, key: key, objectID: id)
        #expect(throws: CryptoError.authenticationFailed) { try ContentCipher.open(sealed, key: key, objectID: UUID()) }
    }

    @Test func wrongKeyIsRejected() throws {
        let sealed = try ContentCipher.seal(message, key: root.objectKey(for: id, purpose: .content), objectID: id)
        let other = try ContentRootKey.generate().objectKey(for: id, purpose: .content)
        #expect(throws: CryptoError.authenticationFailed) { try ContentCipher.open(sealed, key: other, objectID: id) }
    }

    @Test func truncatedCiphertextIsRejected() throws {
        let key = root.objectKey(for: id, purpose: .content)
        #expect(throws: CryptoError.malformedCiphertext) { try ContentCipher.open(Data(), key: key, objectID: id) }
        #expect(throws: CryptoError.malformedCiphertext) { try ContentCipher.open(Data([1, 2, 3]), key: key, objectID: id) }
    }

    @Test func unknownVersionIsRejected() throws {
        let key = root.objectKey(for: id, purpose: .content)
        #expect(throws: CryptoError.unsupportedVersion(9)) { try ContentCipher.open(Data([9]), key: key, objectID: id) }
    }

    @Test("Keys differ by object and purpose, and repeat for the same inputs")
    func derivation() {
        let content = root.objectKey(for: id, purpose: .content)
        #expect(content == root.objectKey(for: id, purpose: .content))
        #expect(content != root.objectKey(for: id, purpose: .metadata))
        #expect(content != root.objectKey(for: UUID(), purpose: .content))
    }

    @Test func wrongSizedKeysAreRejected() {
        #expect(throws: CryptoError.invalidKey) { try ContentRootKey(bytes: Data(count: 31)) }
        #expect(throws: CryptoError.invalidKey) { try ObjectKey(bytes: Data(count: 33)) }
    }
}

@Suite("Recovery key")
struct RecoveryKeyTests {
    @Test func roundTrip() throws {
        let key = try RecoveryKey.generate()
        #expect(try RecoveryKey(encoded: key.encoded) == key)
        #expect(try RecoveryKey(encoded: key.encoded.replacingOccurrences(of: " ", with: "")) == key)
    }

    @Test("Keys with leading zero bytes survive")
    func leadingZeros() throws {
        let key = try RecoveryKey(bytes: Data(repeating: 0, count: 32))
        #expect(try RecoveryKey(encoded: key.encoded) == key)
    }

    // Fixed key: parity misses about 0.4% of typos, so a random key would make this test flaky.
    @Test("Typos in a known key are caught")
    func typosAreCaught() throws {
        let key = try RecoveryKey(bytes: Data(0..<32))
        let text = Array(key.encoded.filter { $0 != " " })
        for index in text.indices {
            var bad = text
            bad[index] = bad[index] == "2" ? "3" : "2"
            #expect(throws: CryptoError.invalidRecoveryKey) { try RecoveryKey(encoded: String(bad)) }
        }
    }

    @Test func nonsenseIsRejected() {
        for text in ["", "0OIl", "hello world"] {
            #expect(throws: CryptoError.invalidRecoveryKey) { try RecoveryKey(encoded: text) }
        }
    }
}

@Suite("Sharing between two users")
struct SharingTests {
    @Test("User 2 opens what user 1 shared, and user 3 cannot")
    func twoUserShare() throws {
        let user2 = try IdentityKeys.generate()
        let user3 = try IdentityKeys.generate()
        let id = UUID()
        let key = try ContentRootKey.generate().objectKey(for: id, purpose: .content)
        let sealed = try ContentCipher.seal(Data("Climbing team schedule".utf8), key: key, objectID: id)

        let wrapped = try key.wrapped(for: user2.bundle())

        #expect(try ContentCipher.open(sealed, key: user2.open(wrapped), objectID: id) == Data("Climbing team schedule".utf8))
        #expect(throws: CryptoError.authenticationFailed) { try user3.open(wrapped) }
    }

    @Test func bundleVerifies() throws {
        try IdentityKeys.generate().bundle().verify()
    }

    @Test("Saved identity keys restore to the same identity")
    func identityRestores() throws {
        let keys = try IdentityKeys.generate()
        let restored = try IdentityKeys(secretData: keys.secretData)
        let key = try ContentRootKey.generate().objectKey(for: UUID(), purpose: .content)
        #expect(try restored.open(key.wrapped(for: keys.bundle())) == key)
        #expect(try restored.bundle().signingPublicKey == keys.bundle().signingPublicKey)
        #expect(throws: CryptoError.invalidKey) { try IdentityKeys(secretData: Data(count: 10)) }
    }

    @Test("A swapped exchange key breaks the bundle, and sealing to it is refused")
    func substitutedKeyIsRejected() throws {
        let victim = try IdentityKeys.generate().bundle()
        let attacker = try IdentityKeys.generate().bundle()
        let forged = IdentityBundle(
            signingPublicKey: victim.signingPublicKey,
            exchangePublicKey: attacker.exchangePublicKey,
            selfSignature: victim.selfSignature
        )
        #expect(throws: CryptoError.invalidSignature) { try forged.verify() }
        let key = try ContentRootKey.generate().objectKey(for: UUID(), purpose: .content)
        #expect(throws: CryptoError.invalidSignature) { try key.wrapped(for: forged) }
    }
}

private final class FakeKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]
    private var failure: KeyStoreError?
    private(set) var saves = 0

    func failReads(with failure: KeyStoreError?) { lock.withLock { self.failure = failure } }

    func load(_ name: String) throws -> Data? {
        try lock.withLock {
            if let failure { throw failure }
            return secrets[name]
        }
    }
    func save(_ data: Data, as name: String) throws {
        lock.withLock {
            secrets[name] = data
            saves += 1
        }
    }
    func delete(_ name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
    func corrupt(_ name: String) { lock.withLock { secrets[name] = Data([1, 2, 3]) } }
}

@Suite struct RootKeyStorageTests {
    private let name = "content-root-key"

    @Test func createsOnceThenKeepsTheSameKey() throws {
        let store = FakeKeyStore()
        let first = try ContentRootKey.loadOrCreate(in: store, hasSealedData: false)
        let second = try ContentRootKey.loadOrCreate(in: store, hasSealedData: false)
        #expect(first == second)
        #expect(store.saves == 1)
    }

    @Test("A failed read never replaces the key, which would orphan every item")
    func failedReadCreatesNothing() throws {
        let store = FakeKeyStore()
        let original = try ContentRootKey.loadOrCreate(in: store, hasSealedData: false)
        store.failReads(with: .unexpectedStatus(-25308))
        #expect(throws: KeyStoreError.unexpectedStatus(-25308)) { try ContentRootKey.loadOrCreate(in: store, hasSealedData: false) }
        #expect(store.saves == 1)
        store.failReads(with: nil)
        #expect(try ContentRootKey.loadOrCreate(in: store, hasSealedData: false) == original)
    }

    @Test("An absent key with data present is refused, so no second key appears beside the data")
    func missingKeyWithDataIsRefused() throws {
        let store = FakeKeyStore()
        #expect(throws: KeyStoreError.keyMissing) { try ContentRootKey.loadOrCreate(in: store, hasSealedData: true) }
        #expect(store.saves == 0)
    }

    @Test func anExistingKeyStillOpensWhenDataIsPresent() throws {
        let store = FakeKeyStore()
        let original = try ContentRootKey.loadOrCreate(in: store, hasSealedData: false)
        #expect(try ContentRootKey.loadOrCreate(in: store, hasSealedData: true) == original)
    }

    @Test func aDamagedKeyIsAnErrorAndIsLeftInPlace() throws {
        let store = FakeKeyStore()
        _ = try ContentRootKey.loadOrCreate(in: store, hasSealedData: false)
        store.corrupt(name)
        #expect(throws: CryptoError.invalidKey) { try ContentRootKey.loadOrCreate(in: store, hasSealedData: false) }
        #expect(store.saves == 1)
    }
}
