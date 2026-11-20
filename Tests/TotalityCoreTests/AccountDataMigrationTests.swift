import Foundation
import Testing
@testable import TotalityCore

final class ListedKeys: ListableKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// Fails the next save, as a full or locked keychain can.
    var failNextSave = false

    func load(_ name: String) throws -> Data? { lock.withLock { items[name] } }
    func save(_ data: Data, as name: String) throws {
        try lock.withLock {
            if failNextSave { failNextSave = false; throw KeyStoreError.unexpectedStatus(-1) }
            items[name] = data
        }
    }
    func delete(_ name: String) throws { _ = lock.withLock { items.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(items.keys) } }
}

/// An install from before content was per account moves, whole and still readable, to its owner.
@Suite struct AccountDataMigrationTests {
    let owner = "account-mckay"
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let content = ListedKeys()
    let google = ListedKeys()

    private func area(_ folder: URL) throws -> SealedArea {
        SealedArea(store: try FileBlobStore(directory: folder.appendingPathComponent("Reader", isDirectory: true)), purposes: [".note": .content])
    }

    /// The owner's device as it was before: one key, claimed by them, a note sealed under it, and a Google sign-in.
    private func oldInstall() throws -> (key: ContentRootKey, note: UUID) {
        let ring = ContentKeyRing(keys: content, areas: [try area(base)])
        try ring.settleExistingInstall(signedInAccount: owner)
        let key = try ring.current()
        let note = UUID()
        let sealed = try ContentCipher.seal(Data("Wittgenstein, §243".utf8), key: key.objectKey(for: note, purpose: .content), objectID: note)
        try FileBlobStore(directory: base.appendingPathComponent("Reader", isDirectory: true)).write(sealed, as: note.uuidString + ".note")
        try google.save(Data("refresh-token-placeholder".utf8), as: "owner@example.com")
        return (key, note)
    }

    private func migration() -> AccountDataMigration {
        AccountDataMigration(contentKeys: content, otherKeys: [google], folders: [base])
    }

    @Test("The owner's key, notes and sign-ins all move to them, and the notes still open")
    func existingDataSurvives() throws {
        let (key, note) = try oldInstall()
        // Someone else is signed in: the content still goes to whoever the key was claimed for.
        #expect(try migration().run(signedInAccount: "someone-else") == owner)
        #expect(try !migration().isNeeded())

        let mine = AccountDataMigration.folder(for: owner, in: base)
        let ring = ContentKeyRing(keys: AccountKeyStore(content, account: owner), areas: [try area(mine)])
        #expect(try ring.current() == key, "the same key, never a new one")
        #expect(try ring.owner() == owner)
        let sealed = try #require(try FileBlobStore(directory: mine.appendingPathComponent("Reader")).read(note.uuidString + ".note"))
        let plain = try ContentCipher.open(sealed, key: ring.current().objectKey(for: note, purpose: .content), objectID: note)
        #expect(String(decoding: plain, as: UTF8.self) == "Wittgenstein, §243")
        #expect(try AccountKeyStore(google, account: owner).load("owner@example.com") != nil)
        #expect(try content.names().allSatisfy { $0.hasPrefix(AccountKeyStore.marker) }, "nothing is left under the old names")
    }

    @Test("A move that stopped halfway finishes on the next launch, losing nothing")
    func interruptedMoveResumes() throws {
        let (key, _) = try oldInstall()
        content.failNextSave = true
        #expect(throws: KeyStoreError.self) { try migration().run(signedInAccount: nil) }
        #expect(try content.load(ContentRootKey.keyStoreName) == key.bytes, "the original stays until its copy is proven")
        #expect(try migration().run(signedInAccount: nil) == owner)
        #expect(try ContentKeyRing(keys: AccountKeyStore(content, account: owner), areas: []).current() == key)
    }

    @Test("Another account signing in starts with its own empty space and its own key")
    func anotherAccountStartsEmpty() throws {
        let (key, _) = try oldInstall()
        try migration().run(signedInAccount: owner)
        let other = "applereview2"
        let theirs = AccountDataMigration.folder(for: other, in: base)
        let ring = ContentKeyRing(keys: AccountKeyStore(content, account: other), areas: [try area(theirs)])
        #expect(try !ring.hasSealedContent())
        #expect(try ring.current() != key)
        #expect(try AccountKeyStore(google, account: other).load("owner@example.com") == nil)
    }

    @Test("An install never claimed waits until someone signs in")
    func unclaimedWaits() throws {
        try content.save(ContentRootKey.generate().bytes, as: ContentRootKey.keyStoreName)
        #expect(try migration().run(signedInAccount: nil) == nil)
        #expect(try migration().isNeeded())
        #expect(try migration().run(signedInAccount: owner) == owner)
    }

    @Test("A different key already in the owner's space is never overwritten, and nobody is locked out")
    func conflictIsSetAside() throws {
        let (key, _) = try oldInstall()
        let theirs = try ContentRootKey.generate()
        try AccountKeyStore(content, account: owner).save(theirs.bytes, as: ContentRootKey.keyStoreName)
        #expect(try migration().run(signedInAccount: nil) == owner)
        #expect(try !migration().blocksOpening())
        #expect(try !migration().isNeeded(), "it doesn't stay pending for ever")
        #expect(try AccountKeyStore(content, account: owner).load(ContentRootKey.keyStoreName) == theirs.bytes)
        let aside = try content.names().filter { $0.hasPrefix(AccountKeyStore.quarantine + owner + "/") && $0.hasSuffix(ContentRootKey.keyStoreName) }
        #expect(try aside.count == 1 && content.load(aside[0]) == key.bytes, "the old key is kept, not lost")
    }

    @Test("An older build writing the old names again is picked up on the next launch")
    func rewrittenItemMovesAgain() throws {
        _ = try oldInstall()
        try migration().run(signedInAccount: nil)
        try google.save(Data("newer-token".utf8), as: "account.owner@example.com")
        #expect(try migration().isNeeded() && !migration().blocksOpening())
        // The key's claim has already moved, so leftovers go to whoever is signed in, as a claim would.
        #expect(try migration().run(signedInAccount: owner) == owner)
        #expect(try AccountKeyStore(google, account: owner).load("account.owner@example.com") == Data("newer-token".utf8))
        #expect(try !migration().isNeeded())
    }

    @Test("Google's own items, named account. and an address, move like everything else")
    func googleTokensMove() throws {
        _ = try oldInstall()
        let index = Data(#"["owner@gmail.com"]"#.utf8)
        try google.save(index, as: "connected")
        try google.save(Data("token-placeholder".utf8), as: "account.owner@gmail.com")
        try migration().run(signedInAccount: nil)
        let mine = AccountKeyStore(google, account: owner)
        #expect(try mine.load("account.owner@gmail.com") == Data("token-placeholder".utf8))
        #expect(try mine.load("connected") == index)
        #expect(try google.load("account.owner@gmail.com") == nil, "no orphan left behind")
    }

    @Test("Giving up sign-ins forgets your own and any from before, never another account's")
    func forgettingIsScoped() {
        let names = [
            AccountKeyStore.prefix(for: owner) + "account.owner@gmail.com",
            AccountKeyStore.prefix(for: "applereview2") + "account.review@gmail.com",
            AccountKeyStore.quarantine + owner + "/x/account.old@gmail.com",
            AccountKeyStore.quarantine + "applereview2/x/account.other@gmail.com",
            "account.legacy@gmail.com",
        ]
        #expect(Set(AccountKeyStore.toForget(in: names, account: owner)) == [names[0], names[2], names[4]])
    }
}
