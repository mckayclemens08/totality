import Foundation
import Testing
@testable import TotalityCore

private final class Blobs: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    /// Throws on this many writes from now, to stand in for a crash partway through.
    var failAfterWrites: Int?

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws {
        try lock.withLock {
            if let remaining = failAfterWrites {
                if remaining == 0 { throw BlobStoreError.invalidName(name) }
                failAfterWrites = remaining - 1
            }
            blobs[name] = data
        }
    }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys).sorted() } }
}

private final class Keys: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    var secrets: [String: Data] = [:]
    /// Throws when this secret is saved, to stand in for a crash right there.
    var failOnSaving: String?

    func load(_ name: String) throws -> Data? { lock.withLock { secrets[name] } }
    func save(_ data: Data, as name: String) throws {
        try lock.withLock {
            if failOnSaving == name {
                failOnSaving = nil
                throw KeyStoreError.keyMissing
            }
            secrets[name] = data
        }
    }
    func delete(_ name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
}

@Suite("Locked secrets, against vectors from Python and OpenSSL")
struct LockedSecretVectorTests {
    private let key = Data(0..<32)
    private let iv = Data(base64Encoded: "EBESExQVFhcYGRobHB0eHw==")!

    @Test func matchesAnIndependentImplementation() throws {
        let locked = try LockedSecret.lock(Data("dGhlIHRlc3Qgcm9vdCBrZXk".utf8), with: key, name: KeyBackup.secretName, iv: iv)
        #expect(locked.ciphertext == "9LAInCNVMqqSZB0fXBlyDM6TrkWe5hw=")
        #expect(locked.mac == "NUM8v8me1SB5jpLwIMDFRNER0V6Zfr7ea3lW0w+IbLU=")
    }

    @Test("The recovery key check is 32 zero bytes under the empty name")
    func matchesTheCheckVector() throws {
        let locked = try LockedSecret.lock(Data(count: 32), with: key, name: "", iv: iv)
        #expect(locked.ciphertext == "qIC5lHzChZ/dfaiCMs/1lDtzaJyFIFQLnMkTz2uKYPI=")
        #expect(locked.mac == "nrMWSgMXBpO1lS9nLEL08Saa+XuAn1pdQ0B7gSgsrQQ=")
    }

    @Test func opensAnIndependentlyMadeSecret() throws {
        let made = LockedSecret(iv: "EBESExQVFhcYGRobHB0eHw==", ciphertext: "9LAInCNVMqqSZB0fXBlyDM6TrkWe5hw=", mac: "NUM8v8me1SB5jpLwIMDFRNER0V6Zfr7ea3lW0w+IbLU=")
        #expect(try made.open(with: key, name: KeyBackup.secretName) == Data("dGhlIHRlc3Qgcm9vdCBrZXk".utf8))
    }

    @Test("Bit 63 of the IV is always clear, as the Matrix spec requires")
    func clearsTheCounterBit() throws {
        for _ in 0..<64 {
            let locked = try LockedSecret.lock(Data([1]), with: key, name: "x")
            let bytes = try #require(Data(base64Encoded: locked.iv))
            #expect(bytes.count == 16)
            #expect(bytes[8] & 0x80 == 0)
        }
    }
}

@Suite struct KeyBackupTests {
    @Test func aRecoveryKeyBringsBackTheRootKey() throws {
        let root = try ContentRootKey.generate()
        let recovery = try RecoveryKey.generate()
        let backup = try KeyBackup.seal(root, with: recovery)
        #expect(backup.opens(with: recovery))
        #expect(try backup.open(with: recovery) == root)
    }

    @Test("It survives being stored and read back as JSON")
    func survivesEncoding() throws {
        let root = try ContentRootKey.generate()
        let recovery = try RecoveryKey.generate()
        let backup = try KeyBackup.seal(root, with: recovery)
        let decoded = try JSONDecoder().decode(KeyBackup.self, from: JSONEncoder().encode(backup))
        #expect(try decoded.open(with: recovery) == root)
    }

    @Test("A typed recovery key opens it, with or without its spaces")
    func typedKeysWork() throws {
        let root = try ContentRootKey.generate()
        let recovery = try RecoveryKey.generate()
        let backup = try KeyBackup.seal(root, with: recovery)
        #expect(try backup.open(with: RecoveryKey(encoded: recovery.encoded)) == root)
        #expect(try backup.open(with: RecoveryKey(encoded: recovery.encoded.replacingOccurrences(of: " ", with: ""))) == root)
    }

    @Test("The copy rebuilt from Matrix, which keeps only the check's IV and MAC, still works")
    func checkWorksWithoutItsCiphertext() throws {
        let root = try ContentRootKey.generate()
        let recovery = try RecoveryKey.generate()
        let backup = try KeyBackup.seal(root, with: recovery)
        let fromMatrix = KeyBackup(
            keyID: backup.keyID, check: LockedSecret(iv: backup.check.iv, ciphertext: "", mac: backup.check.mac), secret: backup.secret
        )
        #expect(fromMatrix.opens(with: recovery))
        #expect(!fromMatrix.opens(with: try RecoveryKey.generate()))
        #expect(try fromMatrix.open(with: recovery) == root)
    }

    @Test("A wrong key fails cleanly and never yields a key")
    func wrongKeyFails() throws {
        let backup = try KeyBackup.seal(ContentRootKey.generate(), with: RecoveryKey.generate())
        let wrong = try RecoveryKey.generate()
        #expect(!backup.opens(with: wrong))
        #expect(throws: CryptoError.authenticationFailed) { try backup.open(with: wrong) }
    }

    @Test("The server can't change what's stored without it being noticed")
    func tamperingIsCaught() throws {
        let recovery = try RecoveryKey.generate()
        let backup = try KeyBackup.seal(ContentRootKey.generate(), with: recovery)
        var bytes = try #require(Data(base64Encoded: backup.secret.ciphertext))
        bytes[0] ^= 1
        let changed = KeyBackup(
            keyID: backup.keyID, check: backup.check,
            secret: LockedSecret(iv: backup.secret.iv, ciphertext: bytes.base64EncodedString(), mac: backup.secret.mac)
        )
        #expect(throws: CryptoError.authenticationFailed) { try changed.open(with: recovery) }
    }

    @Test("A swapped backup can't keep the same fingerprint by reusing the ID")
    func fingerprintCoversTheWholeBackup() throws {
        let recovery = try RecoveryKey.generate()
        let backup = try KeyBackup.seal(ContentRootKey.generate(), with: recovery)
        let other = try KeyBackup.seal(ContentRootKey.generate(), with: recovery)
        let swapped = KeyBackup(keyID: backup.keyID, check: backup.check, secret: other.secret)
        #expect(swapped.fingerprint != backup.fingerprint)
    }

    @Test("The same backup read back from Matrix has the same fingerprint")
    func fingerprintIgnoresWhatMatrixDrops() throws {
        let backup = try KeyBackup.seal(ContentRootKey.generate(), with: RecoveryKey.generate())
        let fromMatrix = KeyBackup(
            keyID: backup.keyID, check: LockedSecret(iv: backup.check.iv, ciphertext: "", mac: backup.check.mac), secret: backup.secret
        )
        #expect(fromMatrix.fingerprint == backup.fingerprint)
    }

    @Test(arguments: ["", "abc", "../../account_data/evil", String(repeating: "G", count: 32), String(repeating: "A", count: 32)])
    func badIDsAreRefused(id: String) throws {
        let backup = try KeyBackup.seal(ContentRootKey.generate(), with: RecoveryKey.generate())
        #expect(!KeyBackup(keyID: id, check: backup.check, secret: backup.secret).hasValidID)
    }

    @Test func aRealIDIsAccepted() throws {
        #expect(try KeyBackup.seal(ContentRootKey.generate(), with: RecoveryKey.generate()).hasValidID)
    }

    @Test("A short IV from a server is refused, not read past its end")
    func shortIVIsRefused() throws {
        let recovery = try RecoveryKey.generate()
        let backup = try KeyBackup.seal(ContentRootKey.generate(), with: recovery)
        let short = KeyBackup(keyID: backup.keyID, check: LockedSecret(iv: "AAAA", ciphertext: "", mac: backup.check.mac), secret: backup.secret)
        #expect(!short.opens(with: recovery))
    }

    @Test("Nothing stored reveals the root key")
    func storesNoPlainKey() throws {
        let root = try ContentRootKey.generate()
        let backup = try KeyBackup.seal(root, with: RecoveryKey.generate())
        let json = try JSONEncoder().encode(backup)
        #expect(json.range(of: root.bytes) == nil)
        #expect(json.range(of: Data(root.bytes.unpaddedBase64.utf8)) == nil)
    }

    @Test func secretsAreNotLockedTheSameWayTwice() throws {
        let root = try ContentRootKey.generate()
        let recovery = try RecoveryKey.generate()
        #expect(try KeyBackup.seal(root, with: recovery).secret != KeyBackup.seal(root, with: recovery).secret)
    }
}

@Suite struct ContentKeyRingTests {
    private let purposes: [String: KeyPurpose] = [".meta": .metadata, ".body": .content]

    private func put(_ text: String, id: UUID, suffix: String, purpose: KeyPurpose, key: ContentRootKey, in blobs: Blobs) throws {
        try blobs.write(
            try ContentCipher.seal(Data(text.utf8), key: key.objectKey(for: id, purpose: purpose), objectID: id),
            as: id.uuidString.lowercased() + suffix
        )
    }

    private func read(id: UUID, suffix: String, purpose: KeyPurpose, key: ContentRootKey, in blobs: Blobs) throws -> String {
        let sealed = try #require(try blobs.read(id.uuidString.lowercased() + suffix))
        return String(decoding: try ContentCipher.open(sealed, key: key.objectKey(for: id, purpose: purpose), objectID: id), as: UTF8.self)
    }

    /// A device with notes under its own key, ready to move to a shared one.
    private func device(notes: Int = 3) throws -> (ring: ContentKeyRing, keys: Keys, blobs: Blobs, old: ContentRootKey, ids: [UUID]) {
        let keys = Keys()
        let blobs = Blobs()
        let ring = ContentKeyRing(keys: keys, areas: [SealedArea(store: blobs, purposes: purposes)])
        let old = try ring.current()
        let ids = (0..<notes).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            try put("title \(index)", id: id, suffix: ".meta", purpose: .metadata, key: old, in: blobs)
            try put("body \(index)", id: id, suffix: ".body", purpose: .content, key: old, in: blobs)
        }
        return (ring, keys, blobs, old, ids)
    }

    private func expectEverythingOpens(_ device: (ring: ContentKeyRing, keys: Keys, blobs: Blobs, old: ContentRootKey, ids: [UUID]), with key: ContentRootKey) throws {
        for (index, id) in device.ids.enumerated() {
            #expect(try read(id: id, suffix: ".meta", purpose: .metadata, key: key, in: device.blobs) == "title \(index)")
            #expect(try read(id: id, suffix: ".body", purpose: .content, key: key, in: device.blobs) == "body \(index)")
        }
    }

    @Test func movesEveryBlobToTheNewKey() throws {
        let device = try device()
        let shared = try ContentRootKey.generate()
        let report = try device.ring.adopt(shared)
        #expect(report == KeyMoveReport(moved: 6, unreadable: 0))
        #expect(try device.ring.current() == shared)
        try expectEverythingOpens(device, with: shared)
    }

    @Test("Nothing is left under the old key afterwards")
    func oldKeyOpensNothing() throws {
        let device = try device()
        _ = try device.ring.adopt(ContentRootKey.generate())
        for id in device.ids {
            #expect(throws: (any Error).self) { _ = try read(id: id, suffix: ".body", purpose: .content, key: device.old, in: device.blobs) }
        }
    }

    @Test("Once finished, the old key is gone from the device")
    func cleansUp() throws {
        let device = try device()
        _ = try device.ring.adopt(ContentRootKey.generate())
        #expect(device.keys.secrets["content-root-key.previous"] == nil)
        #expect(device.keys.secrets["content-root-key.incoming"] == nil)
    }

    @Test("Interrupted at any blob, the next launch finishes and nothing is lost", arguments: 0..<6)
    func resumesAfterACrashPartway(writesBeforeCrash: Int) throws {
        let device = try device()
        let shared = try ContentRootKey.generate()
        device.blobs.failAfterWrites = writesBeforeCrash
        #expect(throws: (any Error).self) { _ = try device.ring.adopt(shared) }
        device.blobs.failAfterWrites = nil

        let relaunched = ContentKeyRing(keys: device.keys, areas: [SealedArea(store: device.blobs, purposes: purposes)])
        #expect(try relaunched.current() == shared)
        try expectEverythingOpens(device, with: shared)
        #expect(device.keys.secrets["content-root-key.incoming"] == nil)
        // Blobs moved before the crash must count as done, not as damaged.
        #expect(device.keys.secrets["content-root-key.previous"] == nil)
    }

    @Test("A crash saving either key at the end still recovers", arguments: ["content-root-key", "content-root-key.incoming", "content-root-key.previous"])
    func resumesAfterACrashSavingAKey(slot: String) throws {
        let device = try device()
        let shared = try ContentRootKey.generate()
        device.keys.failOnSaving = slot
        #expect(throws: (any Error).self) { _ = try device.ring.adopt(shared) }
        device.keys.failOnSaving = nil

        // A crash before anything moved leaves the old key in charge, and the person can try again.
        if device.keys.secrets["content-root-key.incoming"] == nil {
            _ = try device.ring.adopt(shared)
        }
        #expect(try device.ring.current() == shared)
        try expectEverythingOpens(device, with: shared)
    }

    @Test("The window where the key is being replaced can't lose it")
    func survivesTheCurrentKeyBeingMissing() throws {
        let device = try device()
        let shared = try ContentRootKey.generate()
        device.keys.failOnSaving = "content-root-key"
        #expect(throws: (any Error).self) { _ = try device.ring.adopt(shared) }
        // Keychain saves delete first, so a crash there leaves no current key at all.
        device.keys.secrets["content-root-key"] = nil
        #expect(try device.ring.current() == shared)
        try expectEverythingOpens(device, with: shared)
    }

    @Test("A blob neither key opens is left alone, and the old key stays in case it's needed")
    func damagedBlobsAreKept() throws {
        let device = try device(notes: 1)
        let strange = try ContentRootKey.generate()
        let other = UUID()
        try put("from elsewhere", id: other, suffix: ".body", purpose: .content, key: strange, in: device.blobs)
        let before = try device.blobs.read(other.uuidString.lowercased() + ".body")
        let report = try device.ring.adopt(ContentRootKey.generate())
        #expect(report == KeyMoveReport(moved: 2, unreadable: 1))
        #expect(try device.blobs.read(other.uuidString.lowercased() + ".body") == before)
        #expect(device.keys.secrets["content-root-key.previous"] == device.old.bytes)
    }

    @Test("A restored device refuses a key that opens none of its content, and saves nothing")
    func keylessAdoptRefusesTheWrongKey() throws {
        let device = try device()
        device.keys.secrets = [:]
        #expect(throws: ContentKeyError.keyDoesNotOpenContent) { try device.ring.adopt(ContentRootKey.generate()) }
        #expect(device.keys.secrets["content-root-key"] == nil)
    }

    @Test("A restored device reports the items a right key can't open")
    func keylessAdoptReportsPartlyUnreadable() throws {
        let device = try device(notes: 1)
        try put("from elsewhere", id: UUID(), suffix: ".body", purpose: .content, key: ContentRootKey.generate(), in: device.blobs)
        device.keys.secrets = [:]
        #expect(try device.ring.adopt(device.old) == KeyMoveReport(moved: 0, unreadable: 1))
    }

    @Test("A key that opens the content proves whose it is")
    func provenKeyReassigns() throws {
        let device = try device()
        try device.ring.claim(for: "wrong")
        try device.ring.reassign(to: "right", provenBy: device.old)
        #expect(try device.ring.owner() == "right")
    }

    @Test("A key that opens nothing proves nothing")
    func unprovenKeyDoesNotReassign() throws {
        let device = try device()
        try device.ring.claim(for: "first")
        #expect(throws: ContentKeyError.keyDoesNotOpenContent) { try device.ring.reassign(to: "second", provenBy: ContentRootKey.generate()) }
        #expect(try device.ring.owner() == "first")
    }

    @Test("An owner can give up a device, unless it has joined a backup")
    func releaseRules() throws {
        let device = try device()
        try device.ring.claim(for: "first")
        #expect(throws: ContentKeyError.otherAccount) { try device.ring.release(by: "second") }
        try device.ring.release(by: "first")
        #expect(try device.ring.owner() == nil)

        try device.ring.claim(for: "first")
        try device.ring.markJoined("abc")
        #expect(throws: ContentKeyError.notAllowedNow) { try device.ring.release(by: "first") }
        #expect(try device.ring.owner() == "first")
    }

    @Test("An empty device resets to a new key, and its old key can never reach a new backup")
    func emptyDeviceResets() throws {
        let device = try device(notes: 0)
        try device.ring.claim(for: "first")
        try device.ring.markJoined("abc")
        try device.ring.resetEmptyDevice()
        #expect(try device.ring.owner() == nil)
        #expect(try device.ring.joinedBackup() == nil)
        #expect(try device.ring.current() != device.old)
    }

    @Test("A device with any content can never be reset")
    func deviceWithContentNeverResets() throws {
        let device = try device()
        #expect(throws: ContentKeyError.notAllowedNow) { try device.ring.resetEmptyDevice() }
        #expect(try device.ring.current() == device.old)
    }

    @Test("An install from before owners takes its signed-in account, once")
    func existingInstallSettlesOnce() throws {
        let device = try device()
        try device.ring.settleExistingInstall(signedInAccount: "owner")
        #expect(try device.ring.owner() == "owner")
        try device.ring.settleExistingInstall(signedInAccount: "someone-else")
        #expect(try device.ring.owner() == "owner")
    }

    @Test("Signed out on first launch, nothing is claimed, and a later session can't be treated as the old one")
    func signedOutSettlingClaimsNothing() throws {
        let device = try device()
        try device.ring.settleExistingInstall(signedInAccount: nil)
        #expect(try device.ring.owner() == nil)
        try device.ring.settleExistingInstall(signedInAccount: "someone-else")
        #expect(try device.ring.owner() == nil)
    }

    @Test func knowsWhetherSealedContentIsHere() throws {
        #expect(try device(notes: 0).ring.hasSealedContent() == false)
        #expect(try device(notes: 1).ring.hasSealedContent())
    }

    @Test("A stray file doesn't count as someone's content")
    func strayFilesAreNotContent() throws {
        let device = try device(notes: 0)
        try device.blobs.write(Data("not ours".utf8), as: ".DS_Store")
        #expect(try device.ring.hasSealedContent() == false)
    }

    @Test("Moving to the key it already has does nothing")
    func sameKeyIsANoOp() throws {
        let device = try device()
        #expect(try device.ring.adopt(device.old) == KeyMoveReport(moved: 0, unreadable: 0))
    }

    @Test("Every module's storage moves, not just the first")
    func allAreasMove() throws {
        let keys = Keys()
        let notes = Blobs()
        let events = Blobs()
        let ring = ContentKeyRing(keys: keys, areas: [
            SealedArea(store: notes, purposes: purposes),
            SealedArea(store: events, purposes: [".event": .event]),
        ])
        let old = try ring.current()
        let id = UUID()
        try put("dentist", id: id, suffix: ".event", purpose: .event, key: old, in: events)
        let shared = try ContentRootKey.generate()
        #expect(try ring.adopt(shared).moved == 1)
        #expect(try read(id: id, suffix: ".event", purpose: .event, key: shared, in: events) == "dentist")
    }

    @Test("Files it doesn't recognize are left alone")
    func ignoresStrangers() throws {
        let device = try device(notes: 1)
        try device.blobs.write(Data("not ours".utf8), as: "notes.txt")
        #expect(try device.ring.adopt(ContentRootKey.generate()).unreadable == 0)
        #expect(try device.blobs.read("notes.txt") == Data("not ours".utf8))
    }

    @Test("With no key but sealed data, the app stops rather than making a new key")
    func missingKeyStops() throws {
        let device = try device()
        device.keys.secrets = [:]
        #expect(throws: KeyStoreError.keyMissing) { _ = try device.ring.current() }
    }

    @Test("A recovery key restores a device that lost its key, like after a restore")
    func recoveryOpensSealedDataOnAKeylessDevice() throws {
        let device = try device()
        device.keys.secrets = [:]
        let backup = try KeyBackup.seal(device.old, with: RecoveryKey(bytes: Data(repeating: 7, count: 32)))
        let restored = try backup.open(with: RecoveryKey(bytes: Data(repeating: 7, count: 32)))
        #expect(try device.ring.adopt(restored) == KeyMoveReport(moved: 0, unreadable: 0))
        #expect(try device.ring.current() == device.old)
        try expectEverythingOpens(device, with: device.old)
    }

    @Test func remembersWhichBackupItJoined() throws {
        let device = try device()
        #expect(try device.ring.joinedBackup() == nil)
        try device.ring.markJoined("abc123")
        #expect(try device.ring.joinedBackup() == "abc123")
    }

    @Test("A key belongs to the first account that claims it, and no other")
    func aKeyHasOneOwner() throws {
        let device = try device()
        try device.ring.claim(for: "first")
        try device.ring.claim(for: "first")
        #expect(throws: ContentKeyError.otherAccount) { try device.ring.claim(for: "second") }
        #expect(try device.ring.owner() == "first")
    }
}
