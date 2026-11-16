import Foundation
import Testing
@testable import TotalityCore

private let monday = Date(timeIntervalSince1970: 1_800_000_000)

private func freshDefaults() -> UserDefaults {
    let name = "home-choices-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func temporaryStore() throws -> FileBlobStore {
    try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
}

private func key() throws -> ContentRootKey {
    try ContentRootKey(bytes: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
}

@Test func removingHidesAndAddingBackShows() {
    var choices = HomeChoices()
    choices.remove(.photos, at: monday)
    #expect(choices.removed == [.photos])
    choices.restore(.photos, at: monday + 60)
    #expect(choices.removed.isEmpty)
    choices.remove(.photos, at: monday + 120)
    #expect(choices.isRemoved(.photos))
}

@Test func twoDevicesKeepTheLaterChoiceEitherWayRound() {
    var phone = HomeChoices()
    phone.remove(.photos, at: monday)
    phone.remove(.money, at: monday)
    var mac = HomeChoices()
    mac.restore(.photos, at: monday + 60)
    mac.remove(.web, at: monday + 30)
    let one = HomeChoices.merged(phone, mac)
    let other = HomeChoices.merged(mac, phone)
    #expect(one == other)
    #expect(one.removed == [.money, .web])
    #expect(HomeChoices.merged(one, one) == one)
}

@Test func aModuleThisVersionDoesntKnowSurvives() throws {
    let saved = #"{"removedAt":{"shop":800000000,"photos":800000000},"addedAt":{}}"#
    let choices = try JSONDecoder().decode(HomeChoices.self, from: Data(saved.utf8))
    #expect(choices.removed == [.photos])
    let again = try JSONDecoder().decode(HomeChoices.self, from: JSONEncoder().encode(choices))
    #expect(again.removedAt["shop"] != nil)
}

@Test func theRecordIsSealedAndOnlyItsOwnKeyOpensIt() async throws {
    let store = try temporaryStore()
    let mine = try key()
    let book = HomeChoicesBook(store: store, rootKey: mine)
    var choices = HomeChoices()
    choices.remove(.photos, at: monday)
    try await book.add(choices)
    #expect(await book.load().removed == [.photos])

    // The file holds no module names.
    for name in try store.names() {
        let bytes = try #require(try store.read(name))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("photos"))
    }
    // Someone else's key finds nothing it can open, and its record has another ID.
    let theirs = HomeChoicesBook(store: store, rootKey: try key())
    #expect(await theirs.load().removed.isEmpty)
    #expect(await theirs.owner() != nil)
}

@Test func syncTakesOnlyACopyThatOpensUnderThisKey() async throws {
    let store = try temporaryStore()
    let mine = try key()
    let book = HomeChoicesBook(store: store, rootKey: mine)
    var choices = HomeChoices()
    choices.remove(.mail, at: monday)
    try await book.add(choices)
    let id = try #require(try await book.sealedObjectIDs().first)
    let object = try #require(try await book.sealedObject(id))

    // A copy sealed by someone else, under this record's ID, is refused.
    let otherStore = try temporaryStore()
    let other = HomeChoicesBook(store: otherStore, rootKey: try key())
    try await other.add(choices)
    let otherID = try #require(try await other.sealedObjectIDs().first)
    let forged = try #require(try await other.sealedObject(otherID))
    let swapped = SealedObject(id: id, kind: .homeLayout, meta: forged.meta, body: nil)
    await #expect(throws: (any Error).self) { try await book.store(swapped, ifLocalHash: object.hash) }
    #expect(await book.load().removed == [.mail])
}

@Test func aConflictKeepsBothDevicesChoices() async throws {
    let mine = try key()
    let phone = HomeChoicesBook(store: try temporaryStore(), rootKey: mine)
    let mac = HomeChoicesBook(store: try temporaryStore(), rootKey: mine)
    var fromPhone = HomeChoices()
    fromPhone.remove(.photos, at: monday)
    try await phone.add(fromPhone)
    var fromMac = HomeChoices()
    fromMac.remove(.web, at: monday)
    try await mac.add(fromMac)

    let id = try #require(try await phone.sealedObjectIDs().first)
    let local = try #require(try await phone.sealedObject(id))
    let remote = try #require(try await mac.sealedObject(id))
    #expect(try await phone.resolveConflict(local: local, remote: remote) == .keepRemote)
    try await phone.store(remote, ifLocalHash: local.hash)
    #expect(await phone.load().removed == [.photos, .web])
}

@MainActor
@Test func homeShowsTheDevicesCopyBeforeTheKeyOpens() async throws {
    let defaults = freshDefaults()
    let first = HomeChoicesModel(defaults: defaults, now: { monday })
    await first.remove(.photos)
    let later = HomeChoicesModel(defaults: defaults)
    #expect(later.removed == [.photos])
}

@MainActor
@Test func choicesMadeBeforeTheKeyOpensJoinTheRecord() async throws {
    let defaults = freshDefaults()
    let model = HomeChoicesModel(defaults: defaults, now: { monday })
    await model.remove(.money)
    let book = HomeChoicesBook(store: try temporaryStore(), rootKey: try key())
    await model.open(book)
    #expect(await book.load().removed == [.money])
    await model.restore(.money)
    #expect(await book.load().removed.isEmpty)
}

@MainActor
@Test func anotherPersonsChoicesNeverJoin() async throws {
    let defaults = freshDefaults()
    let model = HomeChoicesModel(defaults: defaults, now: { monday })
    let mine = HomeChoicesBook(store: try temporaryStore(), rootKey: try key())
    await model.open(mine)
    await model.remove(.photos)

    // Someone else signs in on this device: their Home starts from their own record.
    model.close()
    let theirs = HomeChoicesBook(store: try temporaryStore(), rootKey: try key())
    await model.open(theirs)
    #expect(model.removed.isEmpty)
    #expect(await theirs.load().removed.isEmpty)
}

@MainActor
@Test func anotherDevicesChoiceArrivesOnReload() async throws {
    let rootKey = try key()
    let store = try temporaryStore()
    let model = HomeChoicesModel(defaults: freshDefaults(), now: { monday })
    let book = HomeChoicesBook(store: store, rootKey: rootKey)
    await model.open(book)
    // What a sync wrote from the other device.
    var fromMac = HomeChoices()
    fromMac.remove(.calls, at: monday + 60)
    try await book.add(fromMac)
    await model.reload()
    #expect(model.removed == [.calls])
}

@Test func keyMovesFindTheRecord() {
    #expect(HomeChoicesBook.sealedPurposes[HomeChoicesBook.suffix] == .homeLayout)
}

// MARK: Refresh and search skip removed modules

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [ModuleID: Int] = [:]
    func add(_ module: ModuleID) { lock.withLock { counts[module, default: 0] += 1 } }
    func count(_ module: ModuleID) -> Int { lock.withLock { counts[module] ?? 0 } }
}

private struct CountingRefresher: ModuleRefresher {
    let module: ModuleID
    let kinds: Set<ContentKind> = []
    let counter: Counter
    func refreshAhead() async { counter.add(module) }
}

private struct NamedSearcher: ModuleSearcher {
    let module: ModuleID
    let kinds: Set<ContentKind> = []
    func search(_ query: String) async throws -> [SearchHit] { [] }
}

@MainActor
@Test func aRemovedModulesRefresherDoesntRun() async throws {
    let counter = Counter()
    let refresh = AppRefresh()
    refresh.registry = try ModuleRegistry(handlers: [
        CountingRefresher(module: .photos, counter: counter), CountingRefresher(module: .mail, counter: counter),
    ])
    refresh.removed = [.photos]
    await refresh.refresh()
    #expect(counter.count(.photos) == 0)
    #expect(counter.count(.mail) == 1)
    refresh.removed = []
    await refresh.refresh()
    #expect(counter.count(.photos) == 1)
}

@Test func homeSearchSkipsRemovedModules() {
    let searchers: [any ModuleSearcher] = [NamedSearcher(module: .reader), NamedSearcher(module: .photos), NamedSearcher(module: .mail)]
    #expect(searchers.onHome(removed: [.photos]).map(\.module) == [.reader, .mail])
    #expect(searchers.onHome(removed: []).count == 3)
}
