import Foundation
import Security
import Testing
@testable import TotalityCore

private let clientID = "204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0.apps.googleusercontent.com"
private let drive = "https://www.googleapis.com/auth/drive"

/// Saving a key or a sign-in replaces it in place. It never deletes first, so a crash or a lock part way
/// through leaves the item that was there.
@Suite struct KeychainSaveTests {
    /// Records which Keychain calls a save makes, answering each with the status it's given.
    final class Calls: @unchecked Sendable {
        var updates: [OSStatus]
        var adds: [OSStatus]
        private(set) var made: [String] = []
        init(updates: [OSStatus], adds: [OSStatus] = []) {
            self.updates = updates
            self.adds = adds
        }
        func update() -> OSStatus { made.append("update"); return updates.removeFirst() }
        func add() -> OSStatus { made.append("add"); return adds.removeFirst() }
        func save() throws { try KeychainKeyStore.upsert(update: update, add: add) }
    }

    @Test func anItemThatsThereIsUpdatedAndNeverAddedOrDeleted() throws {
        let calls = Calls(updates: [errSecSuccess])
        try calls.save()
        #expect(calls.made == ["update"])
    }

    @Test func aMissingItemIsAdded() throws {
        let calls = Calls(updates: [errSecItemNotFound], adds: [errSecSuccess])
        try calls.save()
        #expect(calls.made == ["update", "add"])
    }

    /// Another save added it between this one's update and add: update again, don't fail.
    @Test func anItemAddedMeanwhileIsUpdated() throws {
        let calls = Calls(updates: [errSecItemNotFound, errSecSuccess], adds: [errSecDuplicateItem])
        try calls.save()
        #expect(calls.made == ["update", "add", "update"])
    }

    /// A locked device: the save fails, says so, and tries nothing else, so the old item stays.
    @Test func aFailedUpdateThrowsAndTouchesNothingElse() {
        let calls = Calls(updates: [errSecInteractionNotAllowed])
        #expect(throws: KeyStoreError.unexpectedStatus(errSecInteractionNotAllowed)) { try calls.save() }
        #expect(calls.made == ["update"])
    }

    @Test func aFailedAddThrows() {
        let calls = Calls(updates: [errSecItemNotFound], adds: [errSecInteractionNotAllowed])
        #expect(throws: KeyStoreError.unexpectedStatus(errSecInteractionNotAllowed)) { try calls.save() }
    }

    @Test func anAccountsCornerListsOnlyItsOwnNames() throws {
        let base = ListedKeys()
        try AccountKeyStore(base, account: "a").save(Data([1]), as: "account.one@gmail.com")
        try AccountKeyStore(base, account: "b").save(Data([2]), as: "account.two@gmail.com")
        try base.save(Data([3]), as: "connected")
        #expect(try AccountKeyStore(base, account: "a").names() == ["account.one@gmail.com"])
    }
}

/// A Keychain that can be told to fail its reads, as one can just after launch or while locked.
private final class FlakyKeys: ListableKeyStore, @unchecked Sendable {
    let inner = ListedKeys()
    var failLoads = false
    func load(_ name: String) throws -> Data? {
        if failLoads { throw KeyStoreError.unexpectedStatus(errSecInteractionNotAllowed) }
        return try inner.load(name)
    }
    func save(_ data: Data, as name: String) throws { try inner.save(data, as: name) }
    func delete(_ name: String) throws { try inner.delete(name) }
    func names() throws -> [String] { try inner.names() }
}

/// A failed read or save never loses a Google connection that's there (the crash of 2026-11-21).
@Suite struct GoogleConnectionsSurviveTests {
    private func accounts(_ keys: any KeyStore) throws -> GoogleAccounts {
        GoogleAccounts(signIn: try #require(GoogleSignIn(clientID: clientID, http: NoGoogle())), keychain: keys)
    }

    @Test func aFailedReadThrowsAndTheIndexIsNeverRewrittenFromIt() throws {
        let keys = FlakyKeys()
        let accounts = try accounts(keys)
        try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//one", granted: [drive])
        let index = try keys.inner.load("connected")

        keys.failLoads = true
        #expect(throws: KeyStoreError.self) { try accounts.connections() }
        #expect(throws: KeyStoreError.self) { try accounts.keep(address: "family.clemens@gmail.com", refreshToken: "1//two", granted: [drive]) }
        #expect(throws: KeyStoreError.self) { try accounts.forget("family.clemens@gmail.com") }
        #expect(try keys.inner.load("connected") == index)

        keys.failLoads = false
        #expect(try accounts.connections().map(\.address) == ["mckay.clemens@gmail.com"])
    }

    @Test func aFailedSaveKeepsTheConnectionThatWasThere() throws {
        let keys = ListedKeys()
        let accounts = try accounts(keys)
        let kept = try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//one", granted: [drive])
        keys.failNextSave = true
        #expect(throws: KeyStoreError.self) { try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//newer", granted: [drive, "openid"]) }
        #expect(try accounts.connections() == [kept])
    }

    /// The item was saved but the index wasn't, or the index is gone: the items themselves say what's here.
    @Test func aMissingOrBrokenIndexIsRebuiltFromTheItems() throws {
        let keys = ListedKeys()
        let accounts = try accounts(keys)
        try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//one", granted: [drive])
        try accounts.keep(address: "family.clemens@gmail.com", refreshToken: "1//two", granted: [drive])

        try keys.delete("connected")
        #expect(Set(try accounts.connections().map(\.address)) == ["mckay.clemens@gmail.com", "family.clemens@gmail.com"])

        try keys.save(Data("not an index".utf8), as: "connected")
        #expect(try accounts.connections().count == 2)

        // The next keep writes the repaired index back.
        try accounts.keep(address: "third.clemens@gmail.com", refreshToken: "1//three", granted: [drive])
        let index = try JSONDecoder().decode([String].self, from: try #require(try keys.load("connected")))
        #expect(index.count == 3)
    }

    @Test func forgettingStillForgets() throws {
        let keys = ListedKeys()
        let accounts = try accounts(keys)
        try accounts.keep(address: "mckay.clemens@gmail.com", refreshToken: "1//one", granted: [drive])
        try accounts.forget("mckay.clemens@gmail.com")
        #expect(try accounts.connections().isEmpty)
    }
}

/// Never reached: these tests don't go to Google.
private struct NoGoogle: GoogleHTTP {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}
