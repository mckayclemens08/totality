import Foundation
import Testing
import TotalityCore
import WebKit
@testable import TotalityWeb

@Suite struct WebVaultTests {
    private let site = URL(string: "https://lisbon.example/trams")!
    private let account = "user-1"

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
        try await vault.saveHistory([WebVisit(title: "Tram 28", url: site, date: Date())], for: account)
        try await vault.saveTabs(WebSavedTabs(tabs: [.init(id: UUID(), url: site, title: "Tram 28")], current: nil), for: account)
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
        try await vault.saveHistory([WebVisit(title: "Tram 28", url: site, date: Date())], for: account)
        try await vault.saveTabs(WebSavedTabs(tabs: [.init(id: UUID(), url: site, title: "Tram 28")], current: nil), for: account)
        try await vault.saveSettings(WebSettings(unblockedSites: ["lisbon.example"]), for: account)
        #expect(try await vault.sealedObjectIDs() == [saved.id])
        #expect(vault.kinds == [.bookmark])
    }

    @Test("The site data store stays the same from launch to launch")
    func storeIDLasts() {
        #expect(WebVault.siteID(for: account) == WebVault.siteID(for: account))
    }

    @Test("Reading and empty lists leave nothing behind, so a device nobody used stays empty")
    func emptyLeavesNothing() async throws {
        let store = MemoryBlobStore()
        let vault = try vault(store)
        #expect(try await vault.history(for: account).isEmpty)
        #expect(try await vault.settings(for: account) == WebSettings())
        #expect(try await vault.savedTabs(for: account) == WebSavedTabs())
        #expect(try store.names().isEmpty)
        try await vault.saveHistory([WebVisit(title: "Tram 28", url: site, date: Date())], for: account)
        try await vault.saveHistory([], for: account)
        try await vault.saveTabs(WebSavedTabs(), for: account)
        #expect(try store.names().isEmpty)
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
        await #expect(throws: WebVaultError.closed) { try await vault.saveHistory([], for: account) }
        await #expect(throws: WebVaultError.closed) { try await vault.saveTabs(WebSavedTabs(), for: account) }
    }
}

/// Web's cases for the brief §6 two-user test. A device has one content key, so these use the same key
/// and storage for both people, because that's what two accounts on one device really share.
@MainActor
@Suite struct WebTwoUserTests {
    private let site = URL(string: "https://lisbon.example/trams")!

    @Test("User 2 cannot see user 1's history, tabs, or settings under the same key")
    func user2CannotRead() async throws {
        let vault = WebVault(store: MemoryBlobStore(), rootKey: try .generate())
        try await vault.saveHistory([WebVisit(title: "Tram 28", url: site, date: Date())], for: "user-1")
        try await vault.saveTabs(WebSavedTabs(tabs: [.init(id: UUID(), url: site, title: "Tram 28")], current: nil), for: "user-1")
        try await vault.saveSettings(WebSettings(unblockedSites: ["lisbon.example"]), for: "user-1")

        #expect(try await vault.history(for: "user-2").isEmpty)
        #expect(try await vault.savedTabs(for: "user-2").tabs.isEmpty)
        #expect(try await vault.settings(for: "user-2") == WebSettings())
        #expect(try await vault.history(for: "user-1").count == 1)
    }

    @Test("Two accounts never share a store of site sign-ins")
    func user2HasOwnSignIns() {
        #expect(WebVault.siteID(for: "user-1") != WebVault.siteID(for: "user-2"))
    }

    private func signedIn(_ store: MemoryBlobStore, key: ContentRootKey) async -> WebModel {
        let model = WebModel(client: nil, vault: WebVault(store: store, rootKey: key))
        await model.use(account: "user-1")
        return model
    }

    @Test("Nothing of the owner's shows once they sign out, and it all comes back")
    func signingOutHidesEverything() async throws {
        let store = MemoryBlobStore()
        let model = await signedIn(store, key: try .generate())
        await model.addBookmark(title: "Tram 28", url: site)
        model.open(site)
        let page = try #require(model.current.page)
        page.onVisit?(site, "Tram 28")
        #expect(model.history.count == 1)

        await model.use(account: nil)
        #expect(model.keepsNothing)
        #expect(model.bookmarks.isEmpty)
        #expect(model.history.isEmpty)
        #expect(model.tabs.count == 1)
        #expect(model.current.showing == .start)
        #expect(model.current.page == nil)
        #expect(model.glance?.lines == ["No bookmarks yet"])
        #expect(model.suggestions(for: "tram").isEmpty)

        await model.use(account: "user-1")
        #expect(!model.keepsNothing)
        #expect(model.bookmarks.map(\.title) == ["Tram 28"])
    }

    @Test("Someone who doesn't own the device keeps nothing, and adds nothing to the owner's")
    func nonOwnerKeepsNothing() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let model = WebModel(client: nil, vault: WebVault(store: store, rootKey: key))
        await model.use(account: nil)
        #expect(try store.names().isEmpty)

        await model.addBookmark(title: "Tram 28", url: site)
        #expect(model.bookmarks.isEmpty)
        #expect(model.notice != nil)
        model.open(site)
        try #require(model.current.page).onVisit?(site, "Tram 28")
        model.setBlocking(false, for: "lisbon.example")
        model.newTab()
        #expect(model.history.isEmpty)
        try await Task.sleep(for: .seconds(1))
        #expect(try store.names().isEmpty)
    }

    @Test("A browser opened by a new owner writes nothing, so the device can still pass on")
    func openingWritesNothing() async throws {
        let store = MemoryBlobStore()
        let model = await signedIn(store, key: try .generate())
        model.newTab()
        try await Task.sleep(for: .seconds(1))
        #expect(try store.names().isEmpty)
    }

    @Test("Whoever comes next doesn't get the last person's open tabs")
    func tabsDontCarryOver() async throws {
        let store = MemoryBlobStore()
        let key = try ContentRootKey.generate()
        let vault = WebVault(store: store, rootKey: key)
        try await vault.saveTabs(WebSavedTabs(tabs: [.init(id: UUID(), url: site, title: "Tram 28")], current: nil), for: "user-1")
        let model = await signedIn(store, key: key)
        #expect(model.current.address == site)
        await model.use(account: "user-2")
        #expect(model.current.address == nil)
        #expect(model.current.showing == .start)
    }

    @Test("Sites get a different store for each account, and one that keeps nothing when signed out")
    func storesAreSeparate() async throws {
        let model = WebModel(client: nil, vault: WebVault(store: MemoryBlobStore(), rootKey: try .generate()))
        let accounts = [UUID().uuidString, UUID().uuidString]
        defer {
            for account in accounts { WKWebsiteDataStore.remove(forIdentifier: WebVault.siteID(for: account)) { _ in } }
        }
        func store(_ account: String?) async throws -> WKWebsiteDataStore {
            await model.use(account: account)
            model.open(site)
            let page = try #require(model.current.page)
            page.stop()
            return page.webView.configuration.websiteDataStore
        }
        #expect(try await store(accounts[0]).identifier == WebVault.siteID(for: accounts[0]))
        #expect(try await store(accounts[1]).identifier == WebVault.siteID(for: accounts[1]))
        #expect(try await store(nil).isPersistent == false)
    }

    @Test("Signing every site out can't report done before it knows whose store that is")
    func clearingNeedsToKnowWhoItIs() async throws {
        let model = WebModel(client: nil, vault: WebVault(store: MemoryBlobStore(), rootKey: try .generate()))
        #expect(await model.clearSiteData() == false)
        await model.use(account: nil)
        #expect(await model.clearSiteData())
    }
}
