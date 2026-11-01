import Foundation
import Testing
import TotalityCore
@testable import TotalityWeb

@Suite struct WebVaultTests {
    private let site = URL(string: "https://lisbon.example/trams")!

    private func vault(_ store: MemoryBlobStore = MemoryBlobStore()) throws -> WebVault {
        WebVault(store: store, rootKey: try .generate())
    }

    @Test func aBookmarkComesBack() async throws {
        let vault = try vault()
        let saved = WebBookmark(title: "Tram 28", url: site, folder: "Lisbon")
        try await vault.save(saved)
        #expect(try await vault.bookmarks() == [saved])
        try await vault.delete(saved.id)
        #expect(try await vault.bookmarks().isEmpty)
    }

    @Test("Addresses and titles never reach storage readable")
    func sealed() async throws {
        let store = MemoryBlobStore()
        let vault = try vault(store)
        try await vault.save(WebBookmark(title: "Tram 28", url: site))
        try await vault.saveHistory([WebVisit(title: "Tram 28", url: site, date: Date())])
        try await vault.saveTabs(WebSavedTabs(tabs: [.init(id: UUID(), url: site, title: "Tram 28")], current: nil))
        for name in try store.names() {
            let text = String(decoding: try #require(try store.read(name)), as: UTF8.self)
            #expect(!text.contains("lisbon") && !text.contains("Tram"))
            #expect(!name.contains("lisbon"))
        }
    }

    @Test("Sync sees bookmarks and nothing else")
    func onlyBookmarksSync() async throws {
        let vault = try vault()
        let saved = WebBookmark(title: "Tram 28", url: site)
        try await vault.save(saved)
        try await vault.saveHistory([WebVisit(title: "Tram 28", url: site, date: Date())])
        try await vault.saveTabs(WebSavedTabs())
        _ = try await vault.settings()
        #expect(try await vault.sealedObjectIDs() == [saved.id])
        #expect(vault.kinds == [.bookmark])
    }

    @Test("The site data store stays the same from launch to launch")
    func storeIDLasts() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let first = try await WebVault(store: store, rootKey: key).settings()
        let second = try await WebVault(store: store, rootKey: key).settings()
        #expect(first.storeID == second.storeID)
    }

    @Test("A bookmark from sync must open under this key")
    func refusesForeignObject() async throws {
        let mine = try vault()
        let other = try vault()
        let saved = WebBookmark(title: "Tram 28", url: site)
        try await other.save(saved)
        let object = try #require(try await other.sealedObject(saved.id))
        await #expect(throws: CryptoError.authenticationFailed) { try await mine.store(object, ifLocalHash: nil) }
    }

    @Test("A sealed object can't be passed off under another ID")
    func refusesSwappedID() async throws {
        let store = MemoryBlobStore()
        let vault = try vault(store)
        let a = WebBookmark(title: "A", url: site)
        let b = WebBookmark(title: "B", url: site)
        try await vault.save(a)
        try await vault.save(b)
        let moved = SealedObject(id: b.id, kind: .bookmark, meta: try #require(try await vault.sealedObject(a.id)).meta, body: nil)
        await #expect(throws: (any Error).self) { try await vault.resolveConflict(local: moved, remote: moved) }
    }

    @Test("The newest bookmark wins a conflict")
    func newestWins() async throws {
        let vault = try vault()
        let id = UUID()
        try await vault.save(WebBookmark(id: id, title: "Old", url: site, updatedAt: Date(timeIntervalSince1970: 100)))
        let old = try #require(try await vault.sealedObject(id))
        try await vault.save(WebBookmark(id: id, title: "New", url: site, updatedAt: Date(timeIntervalSince1970: 200)))
        let new = try #require(try await vault.sealedObject(id))
        #expect(try await vault.resolveConflict(local: new, remote: old) == .keepLocal)
        #expect(try await vault.resolveConflict(local: old, remote: new) == .keepRemote)
    }

    @Test("A deletion isn't undone by the copy still on the server")
    func deletionHolds() async throws {
        let vault = try vault()
        let saved = WebBookmark(title: "Tram 28", url: site)
        try await vault.save(saved)
        let object = try #require(try await vault.sealedObject(saved.id))
        try await vault.delete(saved.id)
        #expect(try await vault.deletedObjectIDs() == [saved.id])
        await #expect(throws: SyncError.changedLocally) { try await vault.store(object, ifLocalHash: nil) }
    }

    @Test("Removal by sync keeps a copy in the trash, then the trash empties")
    func trash() async throws {
        let store = MemoryBlobStore()
        let vault = try vault(store)
        let saved = WebBookmark(title: "Tram 28", url: site)
        try await vault.save(saved)
        let hash = try #require(try await vault.sealedHash(of: saved.id))
        try await vault.removeObject(saved.id, ifLocalHash: hash)
        #expect(try await vault.bookmarks().isEmpty)
        let name = "\(saved.id.uuidString.lowercased()).bookmark"
        #expect(try store.read(name + ".trash") != nil)
        let long = Date().addingTimeInterval(-WebVault.trashLifetime - 60)
        try store.write(Data(ISO8601DateFormatter().string(from: long).utf8), as: "\(saved.id.uuidString.lowercased()).trashed")
        try await vault.emptyOldTrash()
        #expect(try store.read(name + ".trash") == nil)
    }

    @Test("A closed vault refuses to write under a key that's moving")
    func closed() async throws {
        let vault = try vault()
        await vault.close()
        await #expect(throws: WebVaultError.closed) { try await vault.save(WebBookmark(title: "A", url: site)) }
        await #expect(throws: WebVaultError.closed) { try await vault.saveHistory([]) }
    }
}

/// Web's cases for the brief §6 two-user test, at the encryption layer.
@Suite struct WebTwoUserTests {
    private let site = URL(string: "https://lisbon.example/trams")!

    @Test("User 2 cannot see user 1's bookmarks, history, or tabs from the same storage")
    func user2CannotRead() async throws {
        let store = MemoryBlobStore()
        let user1 = WebVault(store: store, rootKey: try .generate())
        try await user1.save(WebBookmark(title: "Tram 28", url: site))
        try await user1.saveHistory([WebVisit(title: "Tram 28", url: site, date: Date())])
        try await user1.saveTabs(WebSavedTabs(tabs: [.init(id: UUID(), url: site, title: "Tram 28")], current: nil))

        let user2 = WebVault(store: store, rootKey: try .generate())
        #expect(try await user2.bookmarks().isEmpty)
        await #expect(throws: CryptoError.authenticationFailed) { try await user2.history() }
        await #expect(throws: CryptoError.authenticationFailed) { try await user2.savedTabs() }
    }

    @Test("Two accounts never share a store of site sign-ins")
    func user2HasOwnSignIns() async throws {
        let store = MemoryBlobStore()
        let first = try await WebVault(store: store, rootKey: try .generate()).settings()
        let second = try await WebVault(store: store, rootKey: try .generate()).settings()
        #expect(first.storeID != second.storeID)
    }
}
