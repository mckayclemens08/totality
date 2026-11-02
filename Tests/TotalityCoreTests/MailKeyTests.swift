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
}
