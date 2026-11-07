import Foundation
import Testing
import TotalityCore
@testable import TotalityAccount

/// Supabase Storage's bucket, in memory.
private actor FakeBucket: BucketStore {
    var files: [String: Data] = [:]
    var removeFails = false

    init(_ files: [String: Data] = [:]) { self.files = files }

    func download(_ path: String) async throws -> Data {
        guard let data = files[path] else { throw AccountError.failed }
        return data
    }

    func remove(_ path: String) async throws {
        if removeFails { throw AccountError.failed }
        files[path] = nil
    }

    func setRemoveFails() { removeFails = true }
}

/// The Oracle server's store, in memory, for one account. `failing` makes it unreachable at one step.
private actor FakeSealed: SealedStore {
    enum Step { case put, get }
    var blobs: [UUID: Data] = [:]
    var failing: Step?
    var damageReads = false

    func fail(at step: Step?) { failing = step }
    func damage() { damageReads = true }

    func put(_ sealed: Data, as id: UUID) async throws {
        if failing == .put { throw SealedStoreError.offline }
        if let held = blobs[id] {
            guard held == sealed else { throw SealedStoreError.mismatch }
            return
        }
        blobs[id] = sealed
    }

    func get(_ id: UUID) async throws -> Data? {
        if failing == .get { throw SealedStoreError.offline }
        guard var data = blobs[id] else { return nil }
        if damageReads, !data.isEmpty { data[0] ^= 0xff }
        return data
    }

    func size(of id: UUID) async throws -> Int? { blobs[id]?.count }
    func delete(_ id: UUID) async throws { blobs[id] = nil }
    func usage() async throws -> SealedStoreUsage { SealedStoreUsage(used: blobs.values.reduce(0) { $0 + $1.count }, limit: 1 << 31) }
    func list() async throws -> [SealedStoreEntry] { blobs.map { SealedStoreEntry(id: $0.key, size: $0.value.count) } }
}

/// The rows, in memory: each item's storage key and hash, the way `content_objects` holds them.
private actor FakeRows: MovableRows {
    struct Row { var kind: ContentKind; var key: String; var hash: String; var meta: Data }
    var rows: [UUID: Row] = [:]
    var repointFails = false
    var changeBeforeRepoint: (@Sendable (inout Row) -> Void)?

    func add(_ id: UUID, _ row: Row) { rows[id] = row }
    func setRepointFails() { repointFails = true }
    func changeFirst(_ change: @escaping @Sendable (inout Row) -> Void) { changeBeforeRepoint = change }

    func bucketRows(limit: Int) async throws -> [BucketRow] {
        rows.filter { !SealedBlobKey.isSealed($0.value.key) }.prefix(limit)
            .map { BucketRow(id: $0.key, kind: $0.value.kind, key: $0.value.key, hash: $0.value.hash, meta: $0.value.meta) }
    }

    func repoint(_ id: UUID, from oldKey: String, hash: String, to newKey: String) async throws -> Bool {
        if repointFails { throw AccountError.failed }
        if let change = changeBeforeRepoint, var row = rows[id] {
            change(&row)
            rows[id] = row
            changeBeforeRepoint = nil
        }
        guard let row = rows[id], row.key == oldKey, row.hash == hash else { return false }
        rows[id]?.key = newKey
        return true
    }

    func currentKey(of id: UUID) async throws -> String? { rows[id]?.key }
}

private let owner = UUID().uuidString.lowercased()

private func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

/// One file as an older build left it: its body in the bucket, at the bucket's path for it.
private func oldFile(in bucket: FakeBucket, rows: FakeRows) async -> (id: UUID, object: SealedObject, path: String) {
    let id = UUID()
    let object = SealedObject(id: id, kind: .file, meta: randomBytes(80), body: randomBytes(5_000))
    let path = "\(owner)/\(id.uuidString.lowercased())/\(object.bodyHash!).body"
    await bucket.addFile(path, object.body!)
    await rows.add(id, .init(kind: .file, key: path, hash: object.hash, meta: object.meta))
    return (id, object, path)
}

private extension FakeBucket {
    func addFile(_ path: String, _ data: Data) { files[path] = data }
    func damage(_ path: String) { files[path]?[0] ^= 0xff }
}

@Suite struct BodyMoveTests {
    private func setUp() -> (FakeBucket, FakeSealed, FakeRows, BodyMove) {
        let bucket = FakeBucket()
        let sealed = FakeSealed()
        let rows = FakeRows()
        return (bucket, sealed, rows, BodyMove(rows: rows, bodies: SyncBodies(bucket: bucket, sealed: sealed), owner: owner))
    }

    @Test func movesAFileAndEmptiesTheBucketOnlyAfterTheRowPointsAtTheNewCopy() async throws {
        let (bucket, sealed, rows, move) = setUp()
        let file = await oldFile(in: bucket, rows: rows)
        #expect(try await move.run() == BodyMoveReport(moved: 1, left: 0))
        let key = await rows.rows[file.id]!.key
        let blob = try #require(SealedBlobKey.blob(in: key, owner: owner))
        #expect(await sealed.blobs[blob] == file.object.body)
        #expect(await bucket.files.isEmpty)
        // The item's hash is the same, so sync sees nothing changed.
        #expect(await rows.rows[file.id]!.hash == file.object.hash)
        // And a second run has nothing left to do.
        #expect(try await move.run() == BodyMoveReport())
    }

    @Test func anUnreachableOracleServerLosesNothingAndTheNextRunFinishes() async throws {
        for step in [FakeSealed.Step.put, .get] {
            let (bucket, sealed, rows, move) = setUp()
            let file = await oldFile(in: bucket, rows: rows)
            await sealed.fail(at: step)
            await #expect(throws: SealedStoreError.offline) { try await move.run() }
            #expect(await rows.rows[file.id]!.key == file.path)
            #expect(await bucket.files[file.path] == file.object.body)
            await sealed.fail(at: nil)
            #expect(try await move.run().moved == 1)
            #expect(await bucket.files.isEmpty)
        }
    }

    @Test func aCopyThatDoesntReadBackTheSameIsNeverUsed() async throws {
        let (bucket, sealed, rows, move) = setUp()
        let file = await oldFile(in: bucket, rows: rows)
        await sealed.damage()
        await #expect(throws: SealedStoreError.mismatch) { try await move.run() }
        #expect(await rows.rows[file.id]!.key == file.path)
        #expect(await bucket.files[file.path] == file.object.body)
    }

    @Test func aDamagedBucketCopyIsLeftWhereItIs() async throws {
        let (bucket, sealed, rows, move) = setUp()
        let file = await oldFile(in: bucket, rows: rows)
        await bucket.damage(file.path)
        #expect(try await move.run() == BodyMoveReport(moved: 0, left: 1))
        #expect(await rows.rows[file.id]!.key == file.path)
        #expect(await sealed.blobs.isEmpty)
    }

    @Test func aRowThatChangedMeanwhileKeepsItsBucketCopyAndLeavesNoStrayBlob() async throws {
        let (bucket, sealed, rows, move) = setUp()
        let file = await oldFile(in: bucket, rows: rows)
        let elsewhere = "\(owner)/\(file.id.uuidString.lowercased())/other.body"
        await rows.changeFirst { $0.key = elsewhere; $0.hash = "ffff" }
        #expect(try await move.run() == BodyMoveReport(moved: 0, left: 1))
        #expect(await sealed.blobs.isEmpty)
        #expect(await bucket.files[file.path] == file.object.body)
    }

    @Test func aDatabaseFailureLeavesTheBucketCopy() async throws {
        let (bucket, _, rows, move) = setUp()
        let file = await oldFile(in: bucket, rows: rows)
        await rows.setRepointFails()
        await #expect(throws: AccountError.failed) { try await move.run() }
        #expect(await rows.rows[file.id]!.key == file.path)
        #expect(await bucket.files[file.path] == file.object.body)
    }

    @Test func aBucketThatWontLetGoStillCountsAsMoved() async throws {
        let (bucket, _, rows, move) = setUp()
        _ = await oldFile(in: bucket, rows: rows)
        await bucket.setRemoveFails()
        #expect(try await move.run().moved == 1)
    }

    @Test func onlyThisAccountsOwnBucketFilesAreTouched() async throws {
        let (bucket, sealed, rows, move) = setUp()
        let stranger = UUID().uuidString.lowercased()
        let id = UUID()
        let object = SealedObject(id: id, kind: .file, meta: randomBytes(10), body: randomBytes(10))
        let path = "\(stranger)/\(id.uuidString.lowercased())/\(object.bodyHash!).body"
        await bucket.addFile(path, object.body!)
        await rows.add(id, .init(kind: .file, key: path, hash: object.hash, meta: object.meta))
        #expect(try await move.run() == BodyMoveReport(moved: 0, left: 1))
        #expect(await sealed.blobs.isEmpty)
        #expect(await bucket.files[path] != nil)
    }

    @Test func movesAFewAtATime() async throws {
        let (bucket, _, rows, move) = setUp()
        for _ in 0..<5 { _ = await oldFile(in: bucket, rows: rows) }
        #expect(try await move.run(limit: 2).moved == 2)
        #expect(await bucket.files.count == 3)
    }
}

@Suite struct SyncBodiesTests {
    @Test func newBodiesGoToTheSealedStoreAndOldOnesAreStillRead() async throws {
        let bucket = FakeBucket()
        let sealed = FakeSealed()
        let bodies = SyncBodies(bucket: bucket, sealed: sealed)
        let item = UUID()
        let key = bodies.key(owner: owner, item: item, bodyHash: "ab12")
        #expect(SealedBlobKey.isSealed(key))
        #expect(key.hasPrefix("\(owner)/"))
        try await bodies.write(Data("sealed body".utf8), at: key, owner: owner)
        #expect(try await bodies.read(key, owner: owner) == Data("sealed body".utf8))
        #expect(await bucket.files.isEmpty)

        let old = "\(owner)/\(item.uuidString.lowercased())/cd34.body"
        await bucket.addFile(old, Data("older body".utf8))
        #expect(try await bodies.read(old, owner: owner) == Data("older body".utf8))

        #expect(bodies.holds(key, owner: owner, item: item, bodyHash: "ab12"))
        #expect(bodies.holds(old, owner: owner, item: item, bodyHash: "cd34"))
        #expect(!bodies.holds(key, owner: owner, item: item, bodyHash: "cd34"))

        try await bodies.remove(key, owner: owner)
        try await bodies.remove(old, owner: owner)
        #expect(await sealed.blobs.isEmpty)
        #expect(await bucket.files.isEmpty)
    }

    @Test func aMissingSealedBlobIsAnErrorNeverAnEmptyItem() async throws {
        let bodies = SyncBodies(bucket: FakeBucket(), sealed: FakeSealed())
        let key = bodies.key(owner: owner, item: UUID(), bodyHash: "ab12")
        await #expect(throws: SealedStoreError.unavailable) { try await bodies.read(key, owner: owner) }
        // Someone else's sealed key never reaches the store.
        let theirs = SealedBlobKey.key(owner: UUID().uuidString.lowercased(), blob: UUID())
        await #expect(throws: AccountError.failed) { try await bodies.read(theirs, owner: owner) }
        await #expect(throws: AccountError.failed) { try await bodies.write(Data([1]), at: theirs, owner: owner) }
    }
}
