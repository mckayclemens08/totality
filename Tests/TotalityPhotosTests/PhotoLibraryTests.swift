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
}

struct StoreClient: SealedStore {
    let fake: FakeStore
    let account: String
    func put(_ sealed: Data, as id: UUID) async throws { try await fake.put(sealed, as: id, account: account) }
    func get(_ id: UUID) async throws -> Data? { try await fake.get(id, account: account) }
    func size(of id: UUID) async throws -> Int? { try await fake.get(id, account: account)?.count }
    func delete(_ id: UUID) async throws {}
    func usage() async throws -> SealedStoreUsage { SealedStoreUsage(used: 0, limit: 2_000_000_000) }
    func list() async throws -> [SealedStoreEntry] { [] }
}

/// The rows, per account, the way row-level security keeps them.
actor FakeRows {
    var rows: [String: [UUID: PhotoRow]] = [:]
    var offline = false
    var signedInAsSomeoneElse = false

    func setOffline(_ value: Bool) { offline = value }
    func setSignedInAsSomeoneElse(_ value: Bool) { signedInAsSomeoneElse = value }
    func plant(_ row: PhotoRow, for account: String) { rows[account, default: [:]][row.id] = row }

    func list(account: String) throws -> [PhotoRow] {
        if signedInAsSomeoneElse { throw PhotoRowsWrongAccount() }
        if offline { throw SealedStoreError.offline }
        return Array(rows[account, default: [:]].values)
    }

    func insert(_ row: PhotoRow, account: String) throws {
        if offline { throw SealedStoreError.offline }
        rows[account, default: [:]][row.id] = row
    }
}

struct RowsClient: PhotoRows {
    let fake: FakeRows
    let account: String
    func list() async throws -> [PhotoRow] { try await fake.list(account: account) }
    func insert(_ row: PhotoRow, original: UUID) async throws { try await fake.insert(row, account: account) }
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
    account: String, key: ContentRootKey, store: FakeStore, rows: FakeRows, cache: FileBlobStore? = nil
) throws -> (PhotoLibrary, FileBlobStore) {
    let cache = try cache ?? FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)"))
    return (PhotoLibrary(account: account, rootKey: key, cache: cache, rows: RowsClient(fake: rows, account: account),
                         store: StoreClient(fake: store, account: account)), cache)
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
        #expect(PhotosModel.addNotice(skipped: 1, tooBig: 0) == "One item couldn't be read as a photo.")
        #expect(PhotosModel.addNotice(skipped: 0, tooBig: 2) == "2 photos are over 100 MB, so they weren't added.")
    }

    @Test @MainActor func withoutALibraryPhotosSaysWhy() {
        let model = PhotosModel(library: nil)
        #expect(model.phase == .unavailable(title: PhotosModel.signedOut.title, detail: PhotosModel.signedOut.detail))
        #expect(model.glance == nil)
    }
}
