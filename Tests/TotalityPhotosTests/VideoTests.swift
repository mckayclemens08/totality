import AVFoundation
import CoreVideo
import Foundation
import Testing
import TotalityCore
@testable import TotalityPhotos

/// A real H.264 movie, drawn here rather than shipped as a file: a square that changes colour each frame.
func sampleVideo(seconds: Double = 1, side: Int = 64) async throws -> URL {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let frames = Int(seconds * 10)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for index in 0..<(CVPixelBufferGetBytesPerRow(pixels) * side) { base[index] = UInt8(truncatingIfNeeded: frame * 25 + index % 4 * 60) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return file
}

@Suite struct VideoTests {
    let key = try! ContentRootKey.generate()
    let mckay = UUID().uuidString.lowercased()

    private func library(store: FakeStore, rows: FakeRows) throws -> (PhotoLibrary, FileBlobStore) {
        let cache = try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)"))
        return (PhotoLibrary(account: mckay, rootKey: key, cache: cache, rows: RowsClient(fake: rows, account: mckay),
                             store: StoreClient(fake: store, account: mckay)), cache)
    }

    @Test func readsAVideosLengthSizeAndAThumbnail() async throws {
        let prepared = try await VideoImport.prepare(try await sampleVideo(seconds: 2))
        #expect(abs(prepared.duration - 2) < 0.2)
        #expect(prepared.width == 64 && prepared.height == 64)
        #expect(!prepared.thumbnail.isEmpty)
        await #expect(throws: PhotoError.tooLong) { _ = try await VideoImport.prepare(try await sampleVideo(seconds: 2), maxDuration: 1) }
        let notAVideo = FileManager.default.temporaryDirectory.appendingPathComponent("not-\(UUID().uuidString).mov")
        try Data("Moab trip notes".utf8).write(to: notAVideo)
        await #expect(throws: PhotoError.notAPhoto) { _ = try await VideoImport.prepare(notAVideo) }
    }

    @Test func aVideoIsSealedInChunksUploadedAndPlaysOnAnotherDevice() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (phone, cache) = try library(store: store, rows: rows)
        let file = try await sampleVideo()
        let movie = try Data(contentsOf: file)
        let added = try await phone.addVideo(file)
        #expect(added.details.isVideo)
        // Playable on this device before it uploads.
        #expect(try await phone.movie(of: added).read(0..<movie.count) == movie)
        _ = await phone.upload()
        #expect(try cache.names().filter { $0.contains("waiting") }.isEmpty)
        // The video and its thumbnail, and nothing readable.
        let blobs = await store.all()
        #expect(blobs.count == 2)
        for blob in blobs { #expect(blob.range(of: movie.prefix(64)) == nil) }

        let (mac, macCache) = try library(store: store, rows: rows)
        let item = try #require(try await mac.list().items.first)
        #expect(item.details.isVideo)
        #expect(try await mac.movie(of: item).read(0..<movie.count) == movie)
        #expect(try macCache.names().contains("\(item.id.uuidString.lowercased()).video"))
        await #expect(throws: PhotoError.notAPhoto) { _ = try await mac.original(of: item) }

        try await mac.deleteForGood(item)
        #expect(await store.all().isEmpty)
        #expect(try macCache.names().isEmpty)
    }

    @Test func aLivePhotoKeepsItsStillAndItsMovement() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (phone, _) = try library(store: store, rows: rows)
        let still = samplePhoto()
        let motionFile = try await sampleVideo()
        let motion = try Data(contentsOf: motionFile)
        _ = try await phone.addLive(still: still, motion: motionFile)
        _ = await phone.upload()
        #expect(await store.all().count == 3)

        let (mac, _) = try library(store: store, rows: rows)
        let item = try #require(try await mac.list().items.first)
        #expect(item.details.isLive)
        #expect(try await mac.original(of: item) == still)
        #expect(try await mac.movie(of: item).read(0..<motion.count) == motion)
        try await mac.deleteForGood(item)
        #expect(await store.all().isEmpty)
    }

    @Test func aMovieFromTheServerThatIsntThisPhotosIsRefused() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (phone, _) = try library(store: store, rows: rows)
        let first = try await phone.addVideo(try await sampleVideo())
        let second = try await phone.addVideo(try await sampleVideo())
        _ = await phone.upload()
        await store.swap(first.details.original, second.details.original, for: mckay)
        let (mac, macCache) = try library(store: store, rows: rows)
        let item = try #require(try await mac.list().items.first { $0.id == first.id })
        // Refused as not this photo's, or as bigger than it can be when the two movies' sizes differ.
        do {
            _ = try await mac.movie(of: item)
            Issue.record("A swapped movie opened")
        } catch let error as PhotoError {
            #expect([PhotoError.cantOpen, .tooBig].contains(error))
        }
        // Nothing damaged is kept to be tried again.
        #expect(try macCache.names().filter { $0.contains("video") }.isEmpty)
    }

    @Test func damageAnywhereInAMovieIsCaughtBeforeItsKept() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (phone, _) = try library(store: store, rows: rows)
        let item = try await phone.addVideo(try await sampleVideo(seconds: 3, side: 256))
        _ = await phone.upload()
        guard var sealed = await store.blobs[mckay]?[item.details.original] else { Issue.record("no movie"); return }
        sealed[sealed.count - 20] ^= 0xff
        await store.replace(item.details.original, with: sealed, for: mckay)
        let (mac, macCache) = try library(store: store, rows: rows)
        let seen = try #require(try await mac.list().items.first)
        await #expect(throws: PhotoError.cantOpen) { _ = try await mac.movie(of: seen) }
        #expect(try macCache.names().filter { $0.contains("video") }.isEmpty)
    }

    @Test func twoAsksForOneMovieShareOneDownload() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (phone, _) = try library(store: store, rows: rows)
        let file = try await sampleVideo()
        let movie = try Data(contentsOf: file)
        _ = try await phone.addVideo(file)
        _ = await phone.upload()
        let (mac, _) = try library(store: store, rows: rows)
        let item = try #require(try await mac.list().items.first)
        async let first = mac.movie(of: item)
        async let second = mac.movie(of: item)
        let (a, b) = try await (first, second)
        #expect(try a.read(0..<movie.count) == movie)
        #expect(try b.read(0..<movie.count) == movie)
    }

    @Test func plainCopiesLeftFromAStoppedLaunchAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("plain".utf8).write(to: folder.appendingPathComponent("totality-\(UUID().uuidString).mov"))
        try Data("someone else's".utf8).write(to: folder.appendingPathComponent("other.txt"))
        PhotosModel.removeLeftoverPlainFiles(in: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["other.txt"])
    }

    @Test func onlyTheNewestFewMoviesStayOnTheDevice() async throws {
        let store = FakeStore()
        let rows = FakeRows()
        let (phone, _) = try library(store: store, rows: rows)
        for _ in 0..<(PhotoLibrary.moviesKept + 2) { _ = try await phone.addVideo(try await sampleVideo(seconds: 0.5)) }
        _ = await phone.upload()
        let (mac, macCache) = try library(store: store, rows: rows)
        for item in try await mac.list().items { _ = try await mac.movie(of: item) }
        #expect(try macCache.names().filter { $0.hasSuffix(".video") }.count == PhotoLibrary.moviesKept)
    }
}
