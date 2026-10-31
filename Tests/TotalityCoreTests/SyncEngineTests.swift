import Foundation
import Testing
@testable import TotalityCore

/// A pretend module. Its "sealing" is plain bytes, because the engine must never look inside.
private actor Area: SyncArea {
    nonisolated let kinds: Set<ContentKind> = [.note]
    var objects: [UUID: SealedObject] = [:]
    var conflictAnswer = ConflictResolution.keepLocal
    var conflicts = 0
    var deletions = Set<UUID>()
    var trash: [UUID: SealedObject] = [:]
    var trashSweeps = 0
    var damaged = Set<UUID>()
    /// Runs once, right before a store or removal, to stand in for a save landing mid-sync.
    var beforeWrite: (@Sendable (Area) async -> Void)?
    /// Stands in for a key that doesn't open what arrives.
    var refuseWith: (any Error)?

    func put(_ object: SealedObject) { objects[object.id] = object }
    func answerConflicts(_ answer: ConflictResolution) { conflictAnswer = answer }
    func refuseEverything() { refuseWith = CryptoError.authenticationFailed }
    /// The person deletes it.
    func delete(_ id: UUID) {
        objects[id] = nil
        deletions.insert(id)
    }
    /// The file just vanishes, with no record of anyone deleting it.
    func lose(_ id: UUID) { objects[id] = nil }
    /// A file's bytes go bad on disk.
    func corrupt(_ id: UUID) {
        guard let old = objects[id] else { return }
        objects[id] = SealedObject(id: id, kind: old.kind, meta: old.meta + Data([0]), body: old.body)
        damaged.insert(id)
    }
    func setBeforeWrite(_ action: @escaping @Sendable (Area) async -> Void) { beforeWrite = action }

    func sealedObjectIDs() async throws -> [UUID] { Array(objects.keys) }
    func sealedHash(of id: UUID) async throws -> String? { objects[id]?.hash }
    func sealedObject(_ id: UUID) async throws -> SealedObject? { objects[id] }
    func verifiedObject(_ id: UUID) async throws -> SealedObject? {
        if damaged.contains(id) { throw CryptoError.authenticationFailed }
        return objects[id]
    }
    private func runBeforeWrite() async {
        guard let action = beforeWrite else { return }
        beforeWrite = nil
        await action(self)
    }
    func store(_ object: SealedObject, ifLocalHash: String?) async throws {
        if let refuseWith { throw refuseWith }
        await runBeforeWrite()
        guard objects[object.id]?.hash == ifLocalHash else { throw SyncError.changedLocally }
        if ifLocalHash == nil, deletions.contains(object.id) { throw SyncError.changedLocally }
        objects[object.id] = object
        damaged.remove(object.id)
    }
    func removeObject(_ id: UUID, ifLocalHash: String) async throws {
        await runBeforeWrite()
        guard objects[id]?.hash == ifLocalHash else { throw SyncError.changedLocally }
        trash[id] = objects[id]
        objects[id] = nil
    }
    func emptyOldTrash() async throws { trashSweeps += 1 }
    func deletedObjectIDs() async throws -> Set<UUID> { deletions }
    func clearDeletion(_ id: UUID) async throws { deletions.remove(id) }
    func resolveConflict(local: SealedObject, remote: SealedObject) async throws -> ConflictResolution {
        conflicts += 1
        return conflictAnswer
    }
}

private actor Server: SyncRemote {
    var live: [UUID: SealedObject] = [:]
    var tombstones: [UUID: ContentKind] = [:]
    var failUploads = false
    var failFetches = false
    var failDeletes = false
    /// What `fetch` returns instead of the listed version, like a replayed old copy.
    var stale: [UUID: SealedObject] = [:]
    /// Rows the list leaves out, like a page that came back short.
    var hidden = Set<UUID>()
    private(set) var uploads = 0

    func setFailUploads(_ fail: Bool) { failUploads = fail }
    func setFailFetches(_ fail: Bool) { failFetches = fail }
    func setFailDeletes(_ fail: Bool) { failDeletes = fail }
    func tamper(_ id: UUID, with object: SealedObject) { live[id] = object }
    func serveStale(_ object: SealedObject) { stale[object.id] = object }
    func hide(_ id: UUID) { hidden.insert(id) }
    func markDeleted(_ id: UUID) {
        guard let object = live.removeValue(forKey: id) else { return }
        tombstones[id] = object.kind
    }

    func list() async throws -> [RemoteRecord] {
        live.values.filter { !hidden.contains($0.id) }.map { RemoteRecord(id: $0.id, kind: $0.kind, hash: $0.hash, byteCount: $0.body?.count ?? 0) }
            + tombstones.map { RemoteRecord(id: $0.key, kind: $0.value, hash: nil, byteCount: 0) }
    }
    func fetch(_ id: UUID, reusing local: SealedObject?) async throws -> SealedObject? {
        if failFetches { throw URLError(.notConnectedToInternet) }
        return stale[id] ?? live[id]
    }
    func upload(_ object: SealedObject, expected: String?, replacingDeleted: Bool) async throws {
        if failUploads { throw URLError(.notConnectedToInternet) }
        guard live[object.id]?.hash == expected, (tombstones[object.id] != nil) == replacingDeleted else {
            throw SyncError.changedOnServer
        }
        uploads += 1
        tombstones[object.id] = nil
        live[object.id] = object
    }
    func delete(_ id: UUID, expected: String) async throws {
        if failDeletes { throw URLError(.notConnectedToInternet) }
        guard let object = live[id], object.hash == expected else { throw SyncError.changedOnServer }
        live[id] = nil
        tombstones[id] = object.kind
    }
}

private final class State: SyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: [UUID: String] = [:]
    var failAfterSaves: Int?

    func load() throws -> [UUID: String] { lock.withLock { state } }
    func save(_ new: [UUID: String]) throws {
        try lock.withLock {
            if let remaining = failAfterSaves {
                if remaining == 0 { throw BlobStoreError.invalidName("crash") }
                failAfterSaves = remaining - 1
            }
            state = new
        }
    }
}

private func note(_ id: UUID, _ text: String) -> SealedObject {
    SealedObject(id: id, kind: .note, meta: Data("meta \(text)".utf8), body: Data(text.utf8))
}

private func note(_ text: String) -> SealedObject {
    note(UUID(), text)
}

private struct Device {
    let area = Area()
    let state = State()
    let engine: SyncEngine

    init(server: Server) {
        engine = SyncEngine(areas: [area], remote: server, state: state)
    }
}

@Suite struct SyncEngineTests {
    private let server = Server()

    @Test func aNewItemUploads() async throws {
        let phone = Device(server: server)
        let item = note("first")
        await phone.area.put(item)
        let report = try await phone.engine.sync()
        #expect(report.uploaded == 1)
        #expect(await server.live[item.id] == item)
    }

    @Test func itReachesTheOtherDevice() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let item = note("first")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        let report = try await mac.engine.sync()
        #expect(report.downloaded == 1)
        #expect(report.changedThisDevice)
        #expect(await mac.area.objects[item.id] == item)
    }

    @Test("A new device gets everything")
    func aNewDeviceDownloadsEverything() async throws {
        let phone = Device(server: server)
        for index in 0..<5 { await phone.area.put(note("item \(index)")) }
        _ = try await phone.engine.sync()
        let fresh = Device(server: server)
        #expect(try await fresh.engine.sync().downloaded == 5)
        #expect(await fresh.area.objects.count == 5)
    }

    @Test("Two devices with different content end up with all of it")
    func firstSyncMergesTwoDevices() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        await phone.area.put(note("from phone"))
        await mac.area.put(note("from mac"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        _ = try await phone.engine.sync()
        #expect(await phone.area.objects.count == 2)
        #expect(await mac.area.objects.count == 2)
    }

    @Test("Syncing twice with no changes moves nothing")
    func nothingToDo() async throws {
        let phone = Device(server: server)
        await phone.area.put(note("first"))
        _ = try await phone.engine.sync()
        let second = try await phone.engine.sync()
        #expect(second.uploaded == 0 && second.downloaded == 0 && second.conflicts == 0)
        #expect(await server.uploads == 1)
    }

    @Test func anEditReachesTheOtherDevice() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "one"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await mac.area.put(note(id, "two"))
        #expect(try await mac.engine.sync().uploaded == 1)
        #expect(try await phone.engine.sync().downloaded == 1)
        #expect(await phone.area.objects[id] == note(id, "two"))
    }

    @Test func aDeleteReachesTheOtherDevice() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let item = note("first")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await phone.area.delete(item.id)
        #expect(try await phone.engine.sync().removedThere == 1)
        #expect(await server.tombstones[item.id] != nil)
        #expect(try await mac.engine.sync().removedHere == 1)
        #expect(await mac.area.objects[item.id] == nil)
    }

    @Test("A deleted item never comes back to a device that had it")
    func deletesStick() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let item = note("first")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await phone.area.delete(item.id)
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        _ = try await phone.engine.sync()
        #expect(await phone.area.objects[item.id] == nil)
        #expect(await server.live[item.id] == nil)
    }

    @Test("A new device doesn't download what was deleted")
    func newDevicesSkipDeletedItems() async throws {
        let phone = Device(server: server)
        let item = note("first")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        await phone.area.delete(item.id)
        _ = try await phone.engine.sync()
        let fresh = Device(server: server)
        _ = try await fresh.engine.sync()
        #expect(await fresh.area.objects.isEmpty)
    }

    @Test("Files that vanish are downloaded again, and never delete the server's copies")
    func lostFilesComeBack() async throws {
        let phone = Device(server: server)
        let items = (0..<4).map { note("item \($0)") }
        for item in items { await phone.area.put(item) }
        _ = try await phone.engine.sync()
        for item in items { await phone.area.lose(item.id) }
        let report = try await phone.engine.sync()
        #expect(report.removedThere == 0)
        #expect(report.downloaded == 4)
        #expect(await server.tombstones.isEmpty)
        #expect(await phone.area.objects.count == 4)
    }

    @Test("A save that lands during a pull is never overwritten")
    func aSaveDuringAPullSurvives() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "one"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await mac.area.put(note(id, "from the mac"))
        _ = try await mac.engine.sync()
        await phone.area.setBeforeWrite { await $0.put(note(id, "typed just now")) }
        _ = try await phone.engine.sync()
        #expect(await phone.area.objects[id] == note(id, "typed just now"))
    }

    @Test("A save that lands during a removal isn't thrown away")
    func aSaveDuringARemovalSurvives() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "one"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await mac.area.delete(id)
        _ = try await mac.engine.sync()
        await phone.area.setBeforeWrite { await $0.put(note(id, "typed just now")) }
        _ = try await phone.engine.sync()
        #expect(await phone.area.objects[id] == note(id, "typed just now"))
    }

    @Test("A damaged file here is repaired from the server, and never replaces the good copy")
    func damageIsRepairedNotPushed() async throws {
        let phone = Device(server: server)
        let item = note("good")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        await phone.area.corrupt(item.id)
        let report = try await phone.engine.sync()
        #expect(report.uploaded == 0)
        #expect(await server.live[item.id] == item)
        #expect(await phone.area.objects[item.id] == item)
    }

    @Test("A damaged file with no server copy goes nowhere, and stays here for someone to look at")
    func damageWithNoCopyIsNotUploaded() async throws {
        let phone = Device(server: server)
        let item = note("only here")
        await phone.area.put(item)
        await phone.area.corrupt(item.id)
        #expect(try await phone.engine.sync().rejected == 1)
        #expect(await server.live.isEmpty)
        #expect(await phone.area.objects[item.id] != nil)
    }

    @Test("Removed by another device means trash here, not gone")
    func removalsGoToTrash() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let item = note("first")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await phone.area.delete(item.id)
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        #expect(await mac.area.trash[item.id] == item)
    }

    @Test("If a server says nearly everything was deleted, nothing goes until the person agrees")
    func massRemovalsWait() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let items = (0..<20).map { note("item \($0)") }
        for item in items { await phone.area.put(item) }
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        for item in items { await server.markDeleted(item.id) }
        let held = try await mac.engine.sync()
        #expect(held.heldRemovals == 20)
        #expect(held.removedHere == 0)
        #expect(await mac.area.objects.count == 20)
        let agreed = try await mac.engine.sync(allowLargeRemoval: true)
        #expect(agreed.removedHere == 20)
        #expect(await mac.area.trash.count == 20)
    }

    @Test("Every sync clears out trash that's past its time")
    func syncSweepsTrash() async throws {
        let phone = Device(server: server)
        _ = try await phone.engine.sync()
        #expect(await phone.area.trashSweeps == 1)
    }

    @Test("A few deletes go through without asking")
    func smallRemovalsDoNotAsk() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let items = (0..<20).map { note("item \($0)") }
        for item in items { await phone.area.put(item) }
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        for item in items.prefix(3) { await phone.area.delete(item.id) }
        _ = try await phone.engine.sync()
        let report = try await mac.engine.sync()
        #expect(report.heldRemovals == 0)
        #expect(report.removedHere == 3)
    }

    @Test("What arrives must be what the list promised, so a replayed old copy is ignored")
    func staleFetchesAreRefused() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        let old = note(id, "old")
        await phone.area.put(old)
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await phone.area.put(note(id, "new"))
        _ = try await phone.engine.sync()
        await server.serveStale(old)
        #expect(try await mac.engine.sync().downloaded == 0)
        #expect(await mac.area.objects[id] == old)
    }

    @Test("An item that exists doesn't keep a stale delete record")
    func staleDeletionRecordsClear() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let item = note("first")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await mac.area.delete(item.id)
        await mac.area.put(item)
        _ = try await mac.engine.sync()
        #expect(await mac.area.deletions.isEmpty)
        #expect(await server.live[item.id] == item)
    }

    @Test("A delete that a partial list didn't mention isn't forgotten")
    func pendingDeletesSurviveAShortList() async throws {
        let phone = Device(server: server)
        let item = note("first")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        await phone.area.delete(item.id)
        await server.hide(item.id)
        _ = try await phone.engine.sync()
        #expect(await phone.area.deletions == [item.id])
    }

    @Test("Deleting your only item really deletes it")
    func theLastItemCanBeDeleted() async throws {
        let phone = Device(server: server)
        let item = note("only one")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        await phone.area.delete(item.id)
        #expect(try await phone.engine.sync().removedThere == 1)
        #expect(try await phone.engine.sync().downloaded == 0)
        #expect(await phone.area.objects.isEmpty)
    }

    @Test("Something deleted before it ever synced leaves no record behind")
    func unsyncedDeletesAreForgotten() async throws {
        let phone = Device(server: server)
        await phone.area.delete(UUID())
        _ = try await phone.engine.sync()
        #expect(await phone.area.deletions.isEmpty)
    }

    @Test("A delete that couldn't reach the server is tried again")
    func deletesRetry() async throws {
        let phone = Device(server: server)
        let item = note("first")
        await phone.area.put(item)
        _ = try await phone.engine.sync()
        await phone.area.delete(item.id)
        await server.setFailDeletes(true)
        #expect(try await phone.engine.sync().failed == 1)
        await server.setFailDeletes(false)
        #expect(try await phone.engine.sync().removedThere == 1)
    }

    @Test("Edited here, deleted there: the edit wins, because a lost edit can't be undone")
    func anEditBeatsADelete() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "one"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await phone.area.delete(id)
        _ = try await phone.engine.sync()
        await mac.area.put(note(id, "edited"))
        _ = try await mac.engine.sync()
        _ = try await phone.engine.sync()
        #expect(await phone.area.objects[id] == note(id, "edited"))
        #expect(await server.tombstones[id] == nil)
    }

    @Test("Deleted here, edited there: the edit comes back")
    func aDeleteLosesToARemoteEdit() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "one"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await mac.area.put(note(id, "edited"))
        _ = try await mac.engine.sync()
        await phone.area.delete(id)
        _ = try await phone.engine.sync()
        #expect(await phone.area.objects[id] == note(id, "edited"))
    }

    @Test("Changed on both sides, the module decides, and keeping this device's version uploads it")
    func conflictKeepingLocal() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "one"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await phone.area.put(note(id, "phone"))
        _ = try await phone.engine.sync()
        await mac.area.put(note(id, "mac"))
        await mac.area.answerConflicts(.keepLocal)
        #expect(try await mac.engine.sync().conflicts == 1)
        #expect(await server.live[id] == note(id, "mac"))
    }

    @Test("Keeping the server's version replaces this device's")
    func conflictKeepingRemote() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "one"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await phone.area.put(note(id, "phone"))
        _ = try await phone.engine.sync()
        await mac.area.put(note(id, "mac"))
        await mac.area.answerConflicts(.keepRemote)
        _ = try await mac.engine.sync()
        #expect(await mac.area.objects[id] == note(id, "phone"))
        #expect(await server.live[id] == note(id, "phone"))
    }

    @Test("After a conflict, the next sync has nothing left to do")
    func conflictsSettle() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "one"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await phone.area.put(note(id, "phone"))
        _ = try await phone.engine.sync()
        await mac.area.put(note(id, "mac"))
        _ = try await mac.engine.sync()
        let again = try await mac.engine.sync()
        #expect(again.conflicts == 0 && again.uploaded == 0 && again.downloaded == 0)
    }

    @Test("Something the key doesn't open is refused, and what's here stays")
    func badDataFromTheServerIsRefused() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        let id = UUID()
        await phone.area.put(note(id, "real"))
        _ = try await phone.engine.sync()
        _ = try await mac.engine.sync()
        await server.tamper(id, with: note(id, "forged"))
        await mac.area.refuseEverything()
        #expect(try await mac.engine.sync().rejected == 1)
        #expect(await mac.area.objects[id] == note(id, "real"))
    }

    @Test("A failed upload isn't recorded as done, and the next sync tries again")
    func failedUploadsRetry() async throws {
        let phone = Device(server: server)
        let item = note("first")
        await phone.area.put(item)
        await server.setFailUploads(true)
        #expect(try await phone.engine.sync().failed == 1)
        await server.setFailUploads(false)
        #expect(try await phone.engine.sync().uploaded == 1)
    }

    @Test("One failure doesn't stop the rest")
    func failuresDoNotStopOthers() async throws {
        let (phone, mac) = (Device(server: server), Device(server: server))
        for index in 0..<3 { await phone.area.put(note("item \(index)")) }
        _ = try await phone.engine.sync()
        await server.setFailFetches(true)
        #expect(try await mac.engine.sync().failed == 3)
        await server.setFailFetches(false)
        #expect(try await mac.engine.sync().downloaded == 3)
    }

    @Test("A crash partway leaves the next sync safe, with nothing doubled or lost", arguments: 0..<3)
    func crashesResume(savesBeforeCrash: Int) async throws {
        let phone = Device(server: server)
        for index in 0..<3 { await phone.area.put(note("item \(index)")) }
        phone.state.failAfterSaves = savesBeforeCrash
        _ = try await phone.engine.sync()
        phone.state.failAfterSaves = nil
        let report = try await phone.engine.sync()
        #expect(report.failed == 0)
        #expect(await server.live.count == 3)
        #expect(await phone.area.objects.count == 3)
    }

    @Test("Two devices racing an upload can't overwrite each other unseen")
    func expectedVersionsStopBlindOverwrites() async throws {
        let id = UUID()
        await server.tamper(id, with: note(id, "on the server"))
        await #expect(throws: SyncError.changedOnServer) {
            try await server.upload(note(id, "blind"), expected: nil, replacingDeleted: false)
        }
    }

    @Test("It reports how much space is in use")
    func reportsSpaceUsed() async throws {
        let phone = Device(server: server)
        await phone.area.put(note("1234567890"))
        _ = try await phone.engine.sync()
        #expect(try await phone.engine.sync().byteCount == 10)
    }

    @Test("State survives being saved to a real file")
    func fileStateRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = FileSyncState(file: file)
        #expect(try state.load().isEmpty)
        let id = UUID()
        try state.save([id: "abc"])
        #expect(try FileSyncState(file: file).load() == [id: "abc"])
    }

    @Test("A derived ID is stable, so a retry can't make a second copy")
    func derivedIDsAreStable() {
        #expect(UUID(derivedFrom: "a") == UUID(derivedFrom: "a"))
        #expect(UUID(derivedFrom: "a") != UUID(derivedFrom: "b"))
    }

    @Test("Any change to the sealed bytes changes the hash")
    func hashCoversBothParts() {
        let id = UUID()
        let base = SealedObject(id: id, kind: .note, meta: Data([1]), body: Data([2]))
        #expect(base.hash != SealedObject(id: id, kind: .note, meta: Data([9]), body: Data([2])).hash)
        #expect(base.hash != SealedObject(id: id, kind: .note, meta: Data([1]), body: Data([9])).hash)
        #expect(base.hash == SealedObject(id: id, kind: .note, meta: Data([1]), body: Data([2])).hash)
    }
}
