import Foundation
import Testing
@testable import TotalityCore

/// `sealed` came from the mail server's own code, `server/mail/mail.mjs`, for this key and these IDs,
/// so these tests prove the app can open what the server really writes. The key opens nothing else.
struct MailKeyTests {
    private static let seed = Data(repeating: 0x4D, count: 32)
    private static let publicKey = "f24a1450d7f84eb6112dfc800c8ee33dd74139f6b66ef2b5f03d2cd7de76f93b"
    private static let mailbox = UUID(uuidString: "3f2b8c1e-7a44-4e0b-9d52-1c6f0a9e8b11")!
    private static let message = UUID(uuidString: "a94c07d2-58e3-4b16-8f70-2de1b4c63a05")!
    private static let sealed = Data(base64Encoded: """
        ARKBw/vQmYyN+kSqjANxI/4H+6fxnsBp6NYOgXdmqlMjOv+LbAAznwMg0AiJBOd7NjyoxpDmJpE8AeK+Qfm9JKKpKJFKz24PD6CqmaL/RTla\
        qWE6xgsLPEXJq33O2Or5oHNmQqetxSrH2uq70YHq7ifJ9eZkMWkPxnfTluqF4rKPaN65gTR7Nh+DIXrcFx8Af7dWmfpmB5Ptn9d/2D3rSxw4\
        WD/5eNx1ibJ/dP3b6gTNigYfvG37QdU0WQJvJQhoc6NX+X7VkZp42XATSE3hZ1zSNpR/HzR9A+cRW9s/9gvFHTZODk6QwE0iJeFc
        """)!

    @Test func thePublicKeyMatchesTheServersWorkingOfIt() throws {
        let key = try MailKey(seed: Self.seed)
        #expect(try key.publicKey().map { String(format: "%02x", $0) }.joined() == Self.publicKey)
    }

    @Test func opensWhatTheServerSealed() throws {
        let opened = try MailKey(seed: Self.seed).open(Self.sealed, mailbox: Self.mailbox, message: Self.message)
        let text = String(decoding: opened, as: UTF8.self)
        let parts = text.split(separator: "\n", maxSplits: 1)
        #expect(parts[0] == #"{"version":1,"received":"2026-11-02T19:06:00.000Z","spam":{"score":0.5,"flagged":false}}"#)
        #expect(parts[1] == "From: Charles Babbage <charles@example.org>\r\nSubject: The engine\r\n\r\nThe gears arrived on Tuesday.\r\n")
    }

    @Test func anotherKeyCannotOpenIt() throws {
        let other = try MailKey(seed: Data(repeating: 0x4E, count: 32))
        #expect(throws: CryptoError.authenticationFailed) {
            try other.open(Self.sealed, mailbox: Self.mailbox, message: Self.message)
        }
    }

    @Test func aMessageMovedToAnotherMailboxOrNameWontOpen() throws {
        let key = try MailKey(seed: Self.seed)
        #expect(throws: CryptoError.authenticationFailed) {
            try key.open(Self.sealed, mailbox: UUID(), message: Self.message)
        }
        #expect(throws: CryptoError.authenticationFailed) {
            try key.open(Self.sealed, mailbox: Self.mailbox, message: UUID())
        }
    }

    @Test func aChangedMessageWontOpen() throws {
        var changed = Self.sealed
        changed[changed.count - 1] ^= 1
        #expect(throws: CryptoError.authenticationFailed) {
            try MailKey(seed: Self.seed).open(changed, mailbox: Self.mailbox, message: Self.message)
        }
    }

    @Test func aDifferentVersionOrCutOffMessageIsRefused() throws {
        let key = try MailKey(seed: Self.seed)
        var future = Self.sealed
        future[0] = 2
        #expect(throws: CryptoError.unsupportedVersion(2)) {
            try key.open(future, mailbox: Self.mailbox, message: Self.message)
        }
        #expect(throws: CryptoError.malformedCiphertext) {
            try key.open(Data(), mailbox: Self.mailbox, message: Self.message)
        }
        #expect(throws: CryptoError.malformedCiphertext) {
            try key.open(Self.sealed.prefix(33), mailbox: Self.mailbox, message: Self.message)
        }
    }

    @Test func comesFromTheContentKeyAndNothingElse() throws {
        let root = try ContentRootKey(bytes: Data(repeating: 7, count: 32))
        #expect(try MailKey(root: root).publicKey() == MailKey(root: root).publicKey())
        let other = try ContentRootKey(bytes: Data(repeating: 8, count: 32))
        #expect(try MailKey(root: root).publicKey() != MailKey(root: other).publicKey())
    }

    @Test func refusesASeedOfTheWrongLength() {
        #expect(throws: CryptoError.invalidKey) { try MailKey(seed: Data(count: 31)) }
    }

    // MARK: Mail between accounts

    private static let letter = Data("From: dana@usetotality.com\r\nTo: mckay@usetotality.com\r\nSubject: Saturday's hike\r\n\r\nMeet at the Lost Lake trailhead at 7.\r\n".utf8)
    private static let danaSeed = Data(repeating: 0x44, count: 32)

    @Test func aDirectMessageOpensForItsRecipientWithTheSendersKey() throws {
        let mckay = try MailKey(seed: Self.seed)
        let dana = try MailKey(seed: Self.danaSeed)
        let sealed = try dana.sealDirect(Self.letter, to: mckay.publicKey(), from: "dana", recipient: "mckay", message: Self.message)
        #expect(sealed.first == 1)
        #expect(sealed.count == 1 + 32 + Self.letter.count + 16)
        let danaKey = try dana.publicKey()
        #expect(try mckay.openDirect(sealed, senderKey: danaKey, from: "dana", recipient: "mckay", message: Self.message) == Self.letter)
        #expect(try mckay.openDirect(sealed, senderKey: danaKey, from: "Dana", recipient: "MCKAY", message: Self.message) == Self.letter)
    }

    @Test func aDirectMessageWontOpenForAnotherSenderRecipientOrID() throws {
        let mckay = try MailKey(seed: Self.seed)
        let dana = try MailKey(seed: Self.danaSeed)
        let danaKey = try dana.publicKey()
        let sealed = try dana.sealDirect(Self.letter, to: mckay.publicKey(), from: "dana", recipient: "mckay", message: Self.message)
        #expect(throws: CryptoError.authenticationFailed) { try mckay.openDirect(sealed, senderKey: danaKey, from: "sam", recipient: "mckay", message: Self.message) }
        #expect(throws: CryptoError.authenticationFailed) { try mckay.openDirect(sealed, senderKey: danaKey, from: "dana", recipient: "mckayc", message: Self.message) }
        #expect(throws: CryptoError.authenticationFailed) { try mckay.openDirect(sealed, senderKey: danaKey, from: "dana", recipient: "mckay", message: UUID()) }
        // The name boundaries are fixed, so moving a letter between the names doesn't make a match.
        #expect(throws: CryptoError.authenticationFailed) { try mckay.openDirect(sealed, senderKey: danaKey, from: "danam", recipient: "ckay", message: Self.message) }
        // Nor does it open as ordinary mail.
        #expect(throws: CryptoError.authenticationFailed) { try mckay.open(sealed, mailbox: Self.mailbox, message: Self.message) }
    }

    @Test func aDirectMessageWontOpenWithAnotherKey() throws {
        let mckay = try MailKey(seed: Self.seed)
        let dana = try MailKey(seed: Self.danaSeed)
        let sealed = try dana.sealDirect(Self.letter, to: mckay.publicKey(), from: "dana", recipient: "mckay", message: Self.message)
        let other = try MailKey(seed: Data(repeating: 0x4E, count: 32))
        #expect(throws: CryptoError.authenticationFailed) {
            try other.openDirect(sealed, senderKey: dana.publicKey(), from: "dana", recipient: "mckay", message: Self.message)
        }
    }

    /// The server holds everyone's public keys, and can seal to any of them. It can't seal as anyone.
    @Test func whatTheServerMintsDoesntOpenAsTheSender() throws {
        let mckay = try MailKey(seed: Self.seed)
        let dana = try MailKey(seed: Self.danaSeed)
        let danaKey = try dana.publicKey()
        // Base mode, as step 5 sealed it: anyone with mckay's public key can make this.
        let base = try MailKey.seal(
            Self.letter, to: mckay.publicKey(), info: Data("totality/mail-direct/v2".utf8),
            authenticating: MailKey.directAAD(sender: "dana", recipient: "mckay", message: Self.message), sender: nil
        )
        #expect(throws: CryptoError.authenticationFailed) { try mckay.openDirect(base, senderKey: danaKey, from: "dana", recipient: "mckay", message: Self.message) }
        // Auth mode, but with the server's own key instead of dana's.
        let server = try MailKey(seed: Data(repeating: 0x53, count: 32))
        let minted = try server.sealDirect(Self.letter, to: mckay.publicKey(), from: "dana", recipient: "mckay", message: Self.message)
        #expect(throws: CryptoError.authenticationFailed) { try mckay.openDirect(minted, senderKey: danaKey, from: "dana", recipient: "mckay", message: Self.message) }
    }

    @Test func sealingToSomethingThatIsntAKeyIsRefused() throws {
        let dana = try MailKey(seed: Self.danaSeed)
        #expect(throws: CryptoError.invalidKey) {
            try dana.sealDirect(Self.letter, to: Data(count: 31), from: "dana", recipient: "mckay", message: Self.message)
        }
        #expect(throws: CryptoError.invalidKey) {
            try dana.openDirect(Data(count: 80), senderKey: Data(count: 31), from: "mckay", recipient: "dana", message: Self.message)
        }
    }
}

/// Sent copies: only a device with the content key can make one.
struct MailSentKeyTests {
    private static let account = UUID(uuidString: "3f2b8c1e-7a44-4e0b-9d52-1c6f0a9e8b11")!
    private static let message = UUID(uuidString: "a94c07d2-58e3-4b16-8f70-2de1b4c63a05")!
    private static let copy = Data(#"{"version":1,"received":"2026-11-05T14:30:00.000Z","spam":null,"sent":true}"#.utf8) + Data("\nTo: dana@usetotality.com\r\n\r\nSee you Tuesday.\r\n".utf8)

    @Test func aSentCopyOpensForItsOwnAccountAndMessageOnly() throws {
        let root = try ContentRootKey(bytes: Data(repeating: 0x21, count: 32))
        let key = MailSentKey(root: root)
        let sealed = try key.seal(Self.copy, account: Self.account, message: Self.message)
        #expect(sealed.first == 2)
        #expect(sealed.count == 1 + 12 + Self.copy.count + 16)
        #expect(try key.open(sealed, account: Self.account, message: Self.message) == Self.copy)
        #expect(throws: CryptoError.authenticationFailed) { try key.open(sealed, account: UUID(), message: Self.message) }
        #expect(throws: CryptoError.authenticationFailed) { try key.open(sealed, account: Self.account, message: UUID()) }
    }

    @Test func aSentCopyFromAnotherContentKeyWontOpen() throws {
        let mine = MailSentKey(root: try ContentRootKey(bytes: Data(repeating: 0x21, count: 32)))
        let theirs = MailSentKey(root: try ContentRootKey(bytes: Data(repeating: 0x22, count: 32)))
        let planted = try theirs.seal(Self.copy, account: Self.account, message: Self.message)
        #expect(throws: CryptoError.authenticationFailed) { try mine.open(planted, account: Self.account, message: Self.message) }
    }

    @Test func theStandardSealIsntASentCopy() throws {
        let root = try ContentRootKey(bytes: Data(repeating: 0x21, count: 32))
        let mail = try MailKey(root: root)
        let standard = try mail.publicKey()
        let sealed = try MailKey.seal(Self.copy, to: standard, info: Data("totality/mail/v1".utf8), authenticating: Data(), sender: nil)
        #expect(throws: CryptoError.unsupportedVersion(1)) { try MailSentKey(root: root).open(sealed, account: Self.account, message: Self.message) }
        #expect(throws: CryptoError.malformedCiphertext) { try MailSentKey(root: root).open(Data([2]) + Data(count: 28), account: Self.account, message: Self.message) }
    }
}
