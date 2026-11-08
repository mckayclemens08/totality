import CoreGraphics
import Foundation
import ImageIO
import Testing
import TotalityCore
import UniformTypeIdentifiers
@testable import TotalityPhotos

/// The sealed store on the Oracle server, in memory, shared by every account's client the way the real
/// one is: each account sees only its own blobs.
actor FakeStore {
    /// The server's clock, sent with usage like a `Date` header.
    let clock: Clock
    init(clock: Clock = Clock()) { self.clock = clock }

    var blobs: [String: [UUID: Data]] = [:]
    var offline = false
    var limit = Int.max

    func setOffline(_ value: Bool) { offline = value }
    func setLimit(_ value: Int) { limit = value }
    func replace(_ id: UUID, with data: Data, for account: String) { blobs[account, default: [:]][id] = data }
    func swap(_ a: UUID, _ b: UUID, for account: String) {
        var mine = blobs[account, default: [:]]
        (mine[a], mine[b]) = (mine[b], mine[a])
        blobs[account] = mine
    }

    func put(_ data: Data, as id: UUID, account: String) throws {
        if offline { throw SealedStoreError.offline }
        if blobs[account]?[id] != nil { return }
        let used = blobs[account, default: [:]].values.reduce(0) { $0 + $1.count }
        guard used + data.count <= limit else { throw SealedStoreError.full }
        blobs[account, default: [:]][id] = data
    }

    func get(_ id: UUID, account: String) throws -> Data? {
        if offline { throw SealedStoreError.offline }
        return blobs[account]?[id]
    }

    func all() -> [Data] { blobs.values.flatMap(\.values) }
    func remove(_ id: UUID, account: String) throws {
        if offline { throw SealedStoreError.offline }
        blobs[account]?[id] = nil
    }
}

struct StoreClient: SealedStore {
    let fake: FakeStore
    let account: String
    func put(_ sealed: Data, as id: UUID) async throws { try await fake.put(sealed, as: id, account: account) }
    func get(_ id: UUID) async throws -> Data? { try await fake.get(id, account: account) }
    func size(of id: UUID) async throws -> Int? { try await fake.get(id, account: account)?.count }
    func delete(_ id: UUID) async throws { try await fake.remove(id, account: account) }
    func usage() async throws -> SealedStoreUsage { SealedStoreUsage(used: 0, limit: 2_000_000_000, serverTime: fake.clock.now) }
    func list() async throws -> [SealedStoreEntry] { [] }
}

/// The rows, per account and kind, the way row-level security keeps them.
actor FakeRows {
    /// The server's clock, which stamps each change.
    let clock: Clock
    init(clock: Clock = Clock()) { self.clock = clock }

    var rows: [String: [UUID: PhotoRow]] = [:]
    var albumRows: [String: [UUID: PhotoRow]] = [:]
    var offline = false
    var signedInAsSomeoneElse = false

    func setOffline(_ value: Bool) { offline = value }
    func setSignedInAsSomeoneElse(_ value: Bool) { signedInAsSomeoneElse = value }
    func plant(_ row: PhotoRow, for account: String) { rows[account, default: [:]][row.id] = row }

    private func check() throws {
        if signedInAsSomeoneElse { throw PhotoRowsWrongAccount() }
        if offline { throw SealedStoreError.offline }
    }

    private func table(_ kind: PhotoRowKind, _ account: String) -> [UUID: PhotoRow] {
        (kind == .photo ? rows : albumRows)[account, default: [:]]
    }

    private func set(_ kind: PhotoRowKind, _ account: String, _ id: UUID, _ row: PhotoRow?) {
        let row = row.map { PhotoRow(id: $0.id, details: $0.details, byteCount: $0.byteCount, changed: clock.now) }
        if kind == .photo { rows[account, default: [:]][id] = row } else { albumRows[account, default: [:]][id] = row }
    }

    func list(_ kind: PhotoRowKind, account: String) throws -> [PhotoRow] {
        try check()
        return Array(table(kind, account).values)
    }

    func row(_ id: UUID, kind: PhotoRowKind, account: String) throws -> PhotoRow? {
        try check()
        return table(kind, account)[id]
    }

    /// Puts back an older copy, the way a misbehaving server could.
    func rollBack(_ row: PhotoRow, for account: String) { rows[account, default: [:]][row.id] = row }

    func insert(_ row: PhotoRow, kind: PhotoRowKind, account: String) throws {
        try check()
        set(kind, account, row.id, row)
    }

    func update(_ row: PhotoRow, kind: PhotoRowKind, replacing old: Data, account: String) throws -> Bool {
        try check()
        guard table(kind, account)[row.id]?.details == old else { return false }
        set(kind, account, row.id, row)
        return true
    }

    func delete(_ id: UUID, kind: PhotoRowKind, account: String) throws {
        try check()
        set(kind, account, id, nil)
    }
}

struct RowsClient: PhotoRows {
    let fake: FakeRows
    let account: String
    func list(_ kind: PhotoRowKind) async throws -> [PhotoRow] { try await fake.list(kind, account: account) }
    func row(_ id: UUID, kind: PhotoRowKind) async throws -> PhotoRow? { try await fake.row(id, kind: kind, account: account) }
    func insert(_ row: PhotoRow, kind: PhotoRowKind, original: UUID?) async throws { try await fake.insert(row, kind: kind, account: account) }
    func update(_ row: PhotoRow, kind: PhotoRowKind, replacing old: Data) async throws -> Bool {
        try await fake.update(row, kind: kind, replacing: old, account: account)
    }
    func delete(_ id: UUID, kind: PhotoRowKind) async throws { try await fake.delete(id, kind: kind, account: account) }
}

/// A real JPEG, with a camera date and a location in it, drawn here rather than shipped as a file.
func samplePhoto(width: Int = 1_600, height: Int = 1_200, taken: String = "2026:10:24 17:42:05") -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.85, green: 0.6, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 3))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken, kCGImagePropertyExifOffsetTimeOriginal: "-07:00"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.2338, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 111.6585, kCGImagePropertyGPSLongitudeRef: "W"],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func newLibrary(
    account: String, key: ContentRootKey, store: FakeStore, rows: FakeRows, cache: FileBlobStore? = nil, clock: Clock = Clock()
) throws -> (PhotoLibrary, FileBlobStore) {
    let cache = try cache ?? FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)"))
    return (PhotoLibrary(account: account, rootKey: key, cache: cache, rows: RowsClient(fake: rows, account: account),
                         store: StoreClient(fake: store, account: account), clock: { clock.now }), cache)
}

/// A clock the tests move on.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_000_000)
    var now: Date { lock.withLock { current } }
    func advance(days: Double) { lock.withLock { current += days * 86_400 } }
}

@Suite struct PhotoImportTests {
    @Test func readsTheSizeAndDateAndMakesASmallThumbnailWithNothingInIt() throws {
        let prepared = try PhotoImport.prepare(samplePhoto())
        #expect(prepared.width == 1_600)
        #expect(prepared.height == 1_200)
        #expect(prepared.type == UTType.jpeg.identifier)
        #expect(prepared.taken == ISO8601DateFormatter().date(from: "2026-10-25T00:42:05Z"))
        let source = try #require(CGImageSourceCreateWithData(prepared.thumbnail as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == PhotoImport.thumbnailSide)
        // The place and the date stay in the sealed original, never in the thumbnail.
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
    }

    @Test func refusesWhatIsntAPhoto() {
        #expect(throws: PhotoError.notAPhoto) { try PhotoImport.prepare(Data("Dear Dana, the gears arrived on Tuesday.".utf8)) }
        #expect(throws: PhotoError.notAPhoto) { try PhotoImport.prepare(Data()) }
    }
}

@Suite struct PhotoLibraryTests {
    let key = try! ContentRootKey.generate()
    let mckay = UUID().uuidString.lowercased()

    @Test func aPhotoIsSealedOnTheDeviceUploadedAndOpensOnAnotherDevice() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, cache) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let photo = samplePhoto()
        let added = try await library.add(photo)
        #expect(added.isWaiting)
        #expect(try await library.list().items.map(\.id) == [added.id])

        let report = await library.upload()
        #expect(report == PhotoUploadReport(sent: 1, waiting: 0))
        #expect(try cache.names().sorted() == ["\(added.id.uuidString.lowercased()).details", "\(added.id.uuidString.lowercased()).thumb"])
        let listed = try await library.list()
        #expect(listed.items.map(\.isWaiting) == [false])
        #expect(listed.isCurrent)

        // Nothing on the server can be read: not the photo, the thumbnail, or the details.
        let thumbnail = try PhotoImport.prepare(photo).thumbnail
        for blob in await store.all() + (await rows.rows[mckay]!.values.map(\.details)) {
            #expect(blob.range(of: photo.prefix(64)) == nil)
            #expect(blob.range(of: thumbnail.prefix(64)) == nil)
            #expect(blob.range(of: Data(mckay.utf8)) == nil)
        }

        // The Mac, with the same key and nothing on it yet, sees the same photo.
        let (mac, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try #require(try await mac.list().items.first)
        #expect(item.details == added.details)
        #expect(try await mac.thumbnail(of: item) == thumbnail)
        #expect(try await mac.original(of: item) == photo)
    }

    @Test func nothingIsLostWhenTheServerIsOutOfReach() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let earlier = try await library.add(samplePhoto(taken: "2026:09:01 08:00:00"))
        _ = await library.upload()
        await store.setOffline(true)
        await rows.setOffline(true)
        let waiting = try await library.add(samplePhoto())
        #expect(await library.upload().offline)
        // Offline, the library is what the device saw last, plus what's waiting.
        let offline = try await library.list()
        #expect(!offline.isCurrent)
        #expect(Set(offline.items.map(\.id)) == [earlier.id, waiting.id])
        #expect(try await library.original(of: offline.items.first { $0.id == waiting.id }!) == samplePhoto())
        await store.setOffline(false)
        await rows.setOffline(false)
        #expect(await library.upload() == PhotoUploadReport(sent: 1, waiting: 0))
        #expect(await rows.rows[mckay]?.count == 2)
    }

    @Test func anUploadCutOffBeforeTheRowLeavesNoPhantomAndFinishesLater() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        _ = try await library.add(samplePhoto())
        await rows.setOffline(true)
        #expect(await library.upload().sent == 0)
        #expect(await rows.rows[mckay] == nil)
        await rows.setOffline(false)
        #expect(await library.upload().sent == 1)
        #expect(try await library.list().items.map(\.isWaiting) == [false])
    }

    @Test func aFullAccountStopsAndSaysSo() async throws {
        let store = FakeStore()
        await store.setLimit(1_000)
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: FakeRows())
        _ = try await library.add(samplePhoto())
        let report = await library.upload()
        #expect(report.full)
        #expect(report.waiting == 1)
    }

    @Test func aServerCantSwapThumbnailsOrDetailsBetweenPhotos() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let first = try await library.add(samplePhoto(taken: "2026:01:01 10:00:00"))
        let second = try await library.add(samplePhoto(width: 800, height: 800))
        _ = await library.upload()
        await store.swap(first.details.thumbnail, second.details.thumbnail, for: mckay)
        let (mac, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let items = try await mac.list().items
        for item in items {
            await #expect(throws: PhotoError.cantOpen) { try await mac.thumbnail(of: item) }
        }
        // Details moved onto another row don't open there either.
        let firstRow = await rows.rows[mckay]![first.id]!
        await rows.plant(PhotoRow(id: second.id, details: firstRow.details, byteCount: 1), for: mckay)
        #expect(try await mac.list().unreadable == 1)
    }

    @Test func aClosedLibraryReadsAndWritesNothing() async throws {
        let (library, _) = try newLibrary(account: mckay, key: key, store: FakeStore(), rows: FakeRows())
        await library.close()
        await #expect(throws: PhotoError.closed) { try await library.list() }
        await #expect(throws: PhotoError.closed) { try await library.add(samplePhoto()) }
    }

    @Test func anotherSignInClosesTheLibraryAndShowsNothingItKept() async throws {
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: FakeStore(), rows: rows)
        _ = try await library.add(samplePhoto())
        _ = await library.upload()
        #expect(try await library.list().items.count == 1)
        await rows.setSignedInAsSomeoneElse(true)
        await #expect(throws: PhotoError.closed) { try await library.list() }
        // Unlike being offline, nothing cached comes back, even once the sign-in is right again.
        await rows.setSignedInAsSomeoneElse(false)
        await #expect(throws: PhotoError.closed) { try await library.list() }
    }

    @Test func aServerCantSendMoreThanAPhotoCanBe() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let added = try await library.add(samplePhoto())
        _ = await library.upload()
        await store.replace(added.details.original, with: Data(count: added.details.byteCount + 1_000_000), for: mckay)
        await store.replace(added.details.thumbnail, with: Data(count: 3 * 1024 * 1024), for: mckay)
        let (mac, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try #require(try await mac.list().items.first)
        await #expect(throws: PhotoError.tooBig) { try await mac.original(of: item) }
        await #expect(throws: PhotoError.tooBig) { try await mac.thumbnail(of: item) }
    }

    /// Uploads one photo and returns it as the server has it.
    private func uploaded(_ library: PhotoLibrary) async throws -> PhotoItem {
        _ = try await library.add(samplePhoto())
        _ = await library.upload()
        return try #require(try await library.list().items.first { !$0.isWaiting })
    }

    @Test func favouritesCaptionsAndAlbumsAreSealedAndReachTheOtherDevice() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (phone, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try await uploaded(phone)
        let album = try await phone.makeAlbum(named: "  Zion, October  ")
        #expect(album.name == "Zion, October")
        try await phone.change(item) { $0.isFavourite = true }
        try await phone.change(item) { $0.caption = "Angels Landing at sunrise" }
        try await phone.change(item) { $0.albums = [album.id] }

        for row in Array(await rows.rows[mckay]!.values) + Array(await rows.albumRows[mckay]!.values) {
            #expect(row.details.range(of: Data("Angels Landing".utf8)) == nil)
            #expect(row.details.range(of: Data("Zion".utf8)) == nil)
        }
        let (mac, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let seen = try #require(try await mac.list().items.first)
        #expect(seen.details.favourite)
        #expect(seen.details.caption == "Angels Landing at sunrise")
        #expect(seen.details.albumIDs == [album.id])
        #expect(try await mac.albums().albums == [album])
        let renamed = try await mac.rename(album, to: "Zion")
        #expect(try await phone.albums().albums.map(\.name) == ["Zion"])
        try await phone.deleteAlbum(renamed)
        #expect(try await mac.albums().albums.isEmpty)
        // The photo stays, and the album's ID left in it shows nowhere.
        let after = try await mac.list().items
        #expect(after.count == 1)
        #expect(PhotosModel.items(after, in: .album(album.id), albums: []).isEmpty)
    }

    @Test func aChangeFromAnotherDeviceIsKeptAndThisOneLandsOnTop() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (phone, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let (mac, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try await uploaded(phone)
        _ = try await mac.list()
        // The Mac favourites it while the phone still has the details from before.
        try await mac.change(item) { $0.isFavourite = true }
        let changed = try await phone.change(item) { $0.caption = "Bryce Canyon" }
        #expect(changed.details.caption == "Bryce Canyon")
        #expect(changed.details.favourite)
        let (third, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        #expect(try await third.list().items.first?.details == changed.details)
    }

    @Test func recentlyDeletedKeepsAPhotoForThirtyDaysThenItGoesForGood() async throws {
        let clock = Clock()
        let store = FakeStore(clock: clock)
        let rows = FakeRows(clock: clock)
        let (library, cache) = try newLibrary(account: mckay, key: key, store: store, rows: rows, clock: clock)
        let item = try await uploaded(library)
        try await library.change(item) { $0.trashed = clock.now }
        #expect(PhotosModel.items(try await library.list().items, in: .library, albums: []).isEmpty)
        #expect(PhotosModel.items(try await library.list().items, in: .recentlyDeleted, albums: []).count == 1)

        clock.advance(days: 29)
        #expect(try await library.list().items.count == 1)
        clock.advance(days: 2)
        #expect(try await library.list().items.isEmpty)
        #expect(await rows.rows[mckay]?.isEmpty == true)
        #expect(await store.all().isEmpty)
        #expect(try cache.names().isEmpty)
    }

    @Test func aDeleteCutOffPartwayIsFinishedAndNeverShowsAgain() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, cache) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try await uploaded(library)
        await store.setOffline(true)
        await #expect(throws: SealedStoreError.offline) { try await library.deleteForGood(item) }
        await store.setOffline(false)
        // The row went first, so no device lists it. The files are still there until the next upload.
        #expect(try await library.list().items.isEmpty)
        #expect(await store.all().count == 2)
        _ = await library.upload()
        #expect(await store.all().isEmpty)
        #expect(try cache.names().isEmpty)
    }

    @Test func aRowDeleteThatFailsLeavesThePhotoHiddenUntilItsDone() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try await uploaded(library)
        await rows.setOffline(true)
        await #expect(throws: SealedStoreError.offline) { try await library.deleteForGood(item) }
        #expect(try await library.list().items.isEmpty)
        await rows.setOffline(false)
        #expect(try await library.list().items.isEmpty)
        _ = await library.upload()
        #expect(await rows.rows[mckay]?.isEmpty == true)
        #expect(await store.all().isEmpty)
    }

    @Test func aWaitingPhotoCanBeChangedAndDeletedBeforeItUploads() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        await store.setOffline(true)
        let (library, cache) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try await library.add(samplePhoto())
        let changed = try await library.change(item) { $0.caption = "Kolob Canyons" }
        #expect(changed.isWaiting)
        #expect(try await library.list().items.first?.details.caption == "Kolob Canyons")
        try await library.deleteForGood(changed)
        #expect(try cache.names().isEmpty)
    }

    @Test func albumsFromAnotherAccountOrSwappedBetweenAlbumsNeverOpen() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let dana = UUID().uuidString.lowercased()
        let (mine, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let (hers, _) = try newLibrary(account: dana, key: key, store: store, rows: rows)
        let first = try await mine.makeAlbum(named: "Moab")
        let second = try await mine.makeAlbum(named: "Arches")
        // A server planting my album under her account, or swapping two albums' names, gets nowhere.
        for row in await rows.albumRows[mckay]!.values { try await rows.insert(row, kind: .album, account: dana) }
        #expect(try await hers.albums().albums.isEmpty)
        let a = try #require(await rows.albumRows[mckay]?[first.id])
        let b = try #require(await rows.albumRows[mckay]?[second.id])
        try await rows.insert(PhotoRow(id: a.id, details: b.details, byteCount: 0), kind: .album, account: mckay)
        #expect(try await mine.albums().albums == [second])
    }

    @Test func aWrongClockCantDeleteAnythingForGood() async throws {
        let server = Clock()
        let store = FakeStore(clock: server)
        let rows = FakeRows(clock: server)
        let phone = Clock()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows, clock: phone)
        let item = try await uploaded(library)
        // Put there with a date far in the past, by a device whose clock was wrong.
        try await library.change(item) { $0.trashed = Date(timeIntervalSince1970: 0) }
        phone.advance(days: 40)
        server.advance(days: 40)
        #expect(try await library.list().items.count == 1)
        // Put there today, then listed by a device whose clock is years ahead: the server's clock says no.
        let current = try #require(try await library.list().items.first)
        try await library.change(current) { $0.trashed = phone.now }
        _ = try await library.list()
        phone.advance(days: 900)
        #expect(try await library.list().items.count == 1)
        // Once the server's clock agrees too, it goes.
        server.advance(days: 31)
        #expect(try await library.list().items.isEmpty)
    }

    @Test func aServerRollingAChangeBackIsNotBelieved() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try await uploaded(library)
        try await library.change(item) { $0.caption = "First" }
        let older = try #require(await rows.rows[mckay]?[item.id])
        try await library.change(item) { $0.trashed = Date() }
        await rows.rollBack(older, for: mckay)
        let seen = try #require(try await library.list().items.first)
        #expect(seen.details.trashed != nil)
        await #expect(throws: PhotoError.changedElsewhere) { try await library.change(seen) { $0.caption = "Second" } }
    }

    @Test func aChangeMadeWhileAPhotoUploadsIsntLost() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try await library.add(samplePhoto())
        async let upload = library.upload()
        async let changed = library.change(item) { $0.caption = "Delicate Arch" }
        _ = await upload
        _ = try await changed
        let (mac, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        #expect(try await mac.list().items.first?.details.caption == "Delicate Arch")
    }

    @Test func aPhotoDeletedForGoodWhileItUploadsStaysDeleted() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (library, cache) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let item = try await library.add(samplePhoto())
        async let upload = library.upload()
        async let deleted: Void = library.deleteForGood(item)
        _ = await upload
        try await deleted
        _ = await library.upload()
        #expect(await rows.rows[mckay]?.isEmpty ?? true)
        #expect(await store.all().isEmpty)
        #expect(try cache.names().isEmpty)
    }

    @Test func emptyAlbumNamesAreRefused() async throws {
        let (library, _) = try newLibrary(account: mckay, key: key, store: FakeStore(), rows: FakeRows())
        await #expect(throws: PhotoError.emptyName) { try await library.makeAlbum(named: "   ") }
        #expect(PhotoAlbum.tidy(String(repeating: "a", count: 500))?.count == PhotoAlbum.nameLimit)
    }

    /// Photos' case for the brief §6 two-user test, on the device. The store's own half, with direct
    /// requests, is in `server/blobs/blobs.test.mjs`, and the rows' half is in `backend-tests/photos.test.js`.
    @Test func user2SeesNoneOfUser1sPhotosEvenOnTheSameDevice() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let dana = UUID().uuidString.lowercased()
        let (mine, cache) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let photo = try await mine.add(samplePhoto())
        let waiting = try await mine.add(samplePhoto(width: 640, height: 480))
        await store.setOffline(true)
        _ = await mine.upload()
        await store.setOffline(false)
        _ = await mine.upload()

        // Dana on her own device, and on this one, sharing its cache folder: nothing of McKay's.
        let danaKey = try ContentRootKey.generate()
        let (hers, _) = try newLibrary(account: dana, key: danaKey, store: store, rows: rows)
        #expect(try await hers.list().items.isEmpty)
        let (sameDevice, _) = try newLibrary(account: dana, key: key, store: store, rows: rows, cache: cache)
        #expect(try await sameDevice.list().items.isEmpty)
        #expect(await sameDevice.upload() == PhotoUploadReport())
        await #expect(throws: (any Error).self) { try await hers.thumbnail(of: photo) }
        await #expect(throws: (any Error).self) { try await hers.original(of: photo) }

        // A server that hands McKay's rows to Dana gets them nowhere: the details name McKay.
        for row in await rows.rows[mckay]!.values { await rows.plant(row, for: dana) }
        let planted = try await sameDevice.list()
        #expect(planted.items.isEmpty)
        #expect(planted.unreadable == 2)
        // And McKay's waiting photo stayed McKay's, and went up under McKay.
        #expect(await rows.rows[mckay]?[waiting.id] != nil)
    }
}

@Suite struct PhotosModelTests {
    @Test @MainActor func groupsTheLibraryByMonthNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        func item(_ text: String) -> PhotoItem {
            let date = ISO8601DateFormatter().date(from: text)!
            return PhotoItem(details: PhotoDetails(id: UUID(), owner: "a", original: UUID(), thumbnail: UUID(), added: date, taken: date,
                                                   width: 1, height: 1, type: "public.jpeg", byteCount: 1), isWaiting: false)
        }
        let months = PhotosModel.months(of: [item("2026-11-04T18:00:00Z"), item("2026-11-01T18:00:00Z"), item("2026-10-24T23:42:05Z")], calendar: calendar)
        #expect(months.map(\.items.count) == [2, 1])
        #expect(months.map(\.id) == ["2026-11", "2026-10"])
    }

    @Test func saysPlainlyWhatWasntAdded() {
        #expect(PhotosModel.addNotice(skipped: 0, tooBig: 0) == nil)
        #expect(PhotosModel.addNotice(skipped: 1, tooBig: 0) == "One item couldn't be read as a photo or video.")
        #expect(PhotosModel.addNotice(skipped: 0, tooBig: 2) == "2 items are too big to add.")
        #expect(PhotosModel.addNotice(.init(tooLong: 1)) == "One video is over 10 minutes, so it wasn't added.")
    }

    @Test @MainActor func withoutALibraryPhotosSaysWhy() {
        let model = PhotosModel(library: nil)
        #expect(model.phase == .unavailable(title: PhotosModel.signedOut.title, detail: PhotosModel.signedOut.detail))
        #expect(model.fix == .openAccount)
        #expect(model.glance == nil)
        #expect(model.newest(4).isEmpty)

        let noKey = PhotosModel(library: nil, unavailable: PhotosModel.needsRecoveryKey)
        #expect(noKey.phase == .unavailable(title: PhotosModel.needsRecoveryKey.title, detail: PhotosModel.needsRecoveryKey.detail))
        #expect(noKey.fix == .openAccount)
    }

    @Test @MainActor func theHomeTileShowsTheNewestAndOpensOnlyWhatsStillThere() async throws {
        let key = try ContentRootKey.generate()
        let mckay = UUID().uuidString.lowercased()
        let store = FakeStore()
        let rows = FakeRows()
        let (library, _) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let model = PhotosModel(library: library)
        for side in 0..<5 { _ = try await library.add(samplePhoto(width: 300 + side, height: 200)) }
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.fix == nil)
        let shown = model.newest(4)
        #expect(shown.map(\.id) == Array(model.items(in: .library).prefix(4)).map(\.id))

        // A photo moved to Recently Deleted leaves the tile, and a request for it opens nothing.
        let gone = shown[0]
        await model.moveToRecentlyDeleted(gone)
        #expect(!model.newest(4).contains { $0.id == gone.id })
        model.requestedItem = gone.id
        #expect(model.takeRequest() == nil)
        #expect(model.requestedItem == nil)

        model.requestedItem = shown[1].id
        #expect(model.takeRequest() == shown[1].id)
        #expect(model.requestedItem == nil)
    }

    /// Photos' home tile case for the brief §6 two-user test: Dana's tile on the same device never
    /// shows McKay's photos, and asking it for one of them opens nothing.
    @Test @MainActor func user2sHomeTileShowsNothingOfUser1s() async throws {
        let key = try ContentRootKey.generate()
        let mckay = UUID().uuidString.lowercased()
        let dana = UUID().uuidString.lowercased()
        let store = FakeStore()
        let rows = FakeRows()
        let (mine, cache) = try newLibrary(account: mckay, key: key, store: store, rows: rows)
        let photo = try await mine.add(samplePhoto())
        _ = await mine.upload()

        let (hers, _) = try newLibrary(account: dana, key: key, store: store, rows: rows, cache: cache)
        let model = PhotosModel(library: hers)
        await model.load()
        #expect(model.newest(12).isEmpty)
        #expect(model.glance?.isQuiet == true)
        model.requestedItem = photo.id
        #expect(model.takeRequest() == nil)
    }
}


/// Stands in for Messages: keeps what it was handed, and can be made to fail.
@MainActor
final class FakeSender: PersonSender {
    var unavailableReason: String?
    var longestVideo: Double = 60
    var failAfter: Int?
    private(set) var sentTo: [String] = []
    private(set) var notes: [String] = []
    private(set) var photos: [Data] = []

    func send(
        _ items: [@Sendable () async throws -> OutgoingItem], note: String?, to username: String, progress: @MainActor (Int) -> Void
    ) async -> PersonSendResult {
        sentTo.append(username)
        if let note { notes.append(note) }
        var result = PersonSendResult()
        for load in items {
            if let failAfter, result.sent >= failAfter {
                result.failed += 1
                result.problem = result.problem ?? "The chat couldn't be reached."
                continue
            }
            guard case .photo(let data) = try! await load() else { continue }
            photos.append(data)
            result.sent += 1
            progress(result.sent)
        }
        return result
    }
}

@Suite struct PhotoSharingTests {
    @MainActor private func loaded(_ count: Int) async throws -> (PhotosModel, [Data]) {
        let (library, _) = try newLibrary(account: UUID().uuidString.lowercased(), key: try ContentRootKey.generate(), store: FakeStore(), rows: FakeRows())
        var originals: [Data] = []
        for side in 0..<count {
            let photo = samplePhoto(width: 300 + side, height: 200)
            originals.append(photo)
            _ = try await library.add(photo)
        }
        let model = PhotosModel(library: library)
        await model.load()
        return (model, originals)
    }

    @Test @MainActor func withNoSenderThereIsNothingToShareThrough() async throws {
        let (model, _) = try await loaded(1)
        #expect(await model.share(model.items(in: .library), to: "dana") == "Sharing isn't available here.")
    }

    @Test @MainActor func aShareSendsTheOriginalsOpenedOnTheDeviceAndAnAlbumGoesUnderItsName() async throws {
        let (model, originals) = try await loaded(3)
        let sender = FakeSender()
        model.sender = sender
        #expect(await model.share(model.items(in: .library), albumName: "Moab, October", to: "dana") == nil)
        #expect(sender.sentTo == ["dana"])
        #expect(sender.notes == ["Moab, October, 3 photos"])
        #expect(Set(sender.photos) == Set(originals))
        #expect(model.lastShareSent == 3)
        #expect(model.sharing == nil)
    }

    @Test @MainActor func recentlyDeletedIsNeverSharedAndAGonePhotoIsLeftOut() async throws {
        let (model, _) = try await loaded(3)
        let sender = FakeSender()
        model.sender = sender
        let all = model.items(in: .library)
        await model.moveToRecentlyDeleted(all[0])
        let plan = model.sharePlan(all)
        #expect(plan.items.map(\.id) == Array(all.dropFirst()).map(\.id))
        #expect(await model.share([all[0]], to: "dana") == "There's nothing here to share.")
        #expect(sender.photos.isEmpty)
    }

    @Test @MainActor func whatDidntGoIsSaidPlainly() async throws {
        let (model, _) = try await loaded(3)
        let sender = FakeSender()
        sender.failAfter = 1
        model.sender = sender
        let notice = await model.share(model.items(in: .library), to: "dana")
        #expect(notice == "2 items weren't sent. The chat couldn't be reached.")
        #expect(model.lastShareSent == 1)

        sender.unavailableReason = "Messages runs in the iPhone app."
        #expect(await model.share(model.items(in: .library), to: "dana") == "Messages runs in the iPhone app.")
    }

    @Test func longVideosAndBigSharesAreNamed() {
        let plan = PhotosModel.SharePlan(items: [], tooLong: 2, overLimit: 4)
        #expect(PhotosModel.shareNotice(PersonSendResult(sent: 50), plan: plan, longest: 60)
            == "2 videos were too long to share. Only the first 50 were sent. Share the rest separately.")
        #expect(PhotosModel.tooLongNotice(60) == "Videos over a minute can't be shared in a chat.")
    }
}
