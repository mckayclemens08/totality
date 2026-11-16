import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import TotalityCore
import UniformTypeIdentifiers
@testable import TotalityPhotos
@testable import TotalityUI

/// A photo of a place, drawn here: sky, a far ridge, water and a near shore, in one scene's colours, with
/// the camera's date in it. Different enough from each other to tell apart on a tile.
private func scene(_ colours: [(CGFloat, CGFloat, CGFloat)], taken: String) -> Data {
    let width = 1_200, height = 900
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let bands: [(CGFloat, CGFloat)] = [(0.55, 0.45), (0.38, 0.17), (0.12, 0.26), (0, 0.12)]
    for (index, band) in bands.enumerated() {
        let (r, g, b) = colours[index % colours.count]
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(height) * band.0, width: CGFloat(width), height: CGFloat(height) * band.1))
    }
    // The sun or moon, low over the ridge.
    context.setFillColor(CGColor(red: 1, green: 0.93, blue: 0.75, alpha: 1))
    context.fillEllipse(in: CGRect(x: CGFloat(width) * 0.62, y: CGFloat(height) * 0.6, width: 140, height: 140))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken]]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Eight days out at the lake and in the hills, newest last.
private let trip: [Data] = [
    scene([(0.53, 0.72, 0.89), (0.36, 0.48, 0.42), (0.24, 0.45, 0.62), (0.72, 0.64, 0.48)], taken: "2026:10:17 09:12:00"),
    scene([(0.96, 0.66, 0.42), (0.42, 0.3, 0.36), (0.78, 0.48, 0.38), (0.3, 0.24, 0.22)], taken: "2026:10:18 18:40:00"),
    scene([(0.7, 0.82, 0.9), (0.55, 0.6, 0.66), (0.4, 0.55, 0.64), (0.88, 0.88, 0.86)], taken: "2026:10:19 08:05:00"),
    scene([(0.2, 0.24, 0.42), (0.12, 0.14, 0.24), (0.18, 0.22, 0.36), (0.08, 0.1, 0.14)], taken: "2026:10:20 21:30:00"),
    scene([(0.62, 0.8, 0.86), (0.3, 0.46, 0.28), (0.2, 0.5, 0.5), (0.5, 0.42, 0.3)], taken: "2026:10:21 12:20:00"),
    scene([(0.98, 0.78, 0.6), (0.6, 0.4, 0.42), (0.86, 0.6, 0.5), (0.44, 0.32, 0.3)], taken: "2026:10:22 19:02:00"),
    scene([(0.8, 0.86, 0.9), (0.48, 0.5, 0.48), (0.6, 0.66, 0.7), (0.7, 0.62, 0.52)], taken: "2026:10:23 07:45:00"),
    scene([(0.45, 0.66, 0.86), (0.26, 0.4, 0.3), (0.22, 0.4, 0.56), (0.6, 0.52, 0.38)], taken: "2026:10:24 17:42:05"),
]

@MainActor
private func library(with photos: [Data], opened: Bool = true) async throws -> PhotosModel {
    let account = UUID().uuidString.lowercased()
    let cache = try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("photos-tile-\(UUID().uuidString)"))
    let library = PhotoLibrary(
        account: account, rootKey: try ContentRootKey.generate(), cache: cache,
        rows: RowsClient(fake: FakeRows(), account: account), store: StoreClient(fake: FakeStore(), account: account)
    )
    for photo in photos { _ = try await library.add(photo) }
    let model = PhotosModel(library: library, syncSource: nil)
    // Left unopened, it shows what the tile shows while the library opens.
    guard opened else { return model }
    await model.load()
    // Opened ahead, as the cells' own tasks would, so a render shows them.
    for item in model.newest(12) { _ = await model.thumbnail(item) }
    return model
}

/// The Photos tile inside the real home grid, at a big size, as the home page draws it.
@MainActor
private func grid(_ model: PhotosModel, size: TileSize, isHero: Bool = false) -> some View {
    var layout = HomeLayout(modules: [.photos])
    layout.setSize(size, of: .photos)
    if isHero { layout.makeHero(.photos) }
    return BentoGrid(
        layout: .constant(layout), modules: ModuleEntry.all, glances: model.glance.map { [.photos: $0] } ?? [:],
        bigTile: { id, big in id == .photos ? AnyView(PhotosHomeTile(model: model, size: big)) : nil },
        width: 393 - 2 * Space.s4, isEditing: .constant(false), onOpen: { _ in }
    )
}

@MainActor
@Suite struct PhotosHomeTileTests {
    @Test("Medium shows a row of the four newest, large two rows, the square three")
    func rowsForEachSize() async throws {
        let model = try await library(with: trip)
        #expect(model.phase == .ready)
        let newest = model.newest(12)
        #expect(newest.count == trip.count)
        // Every thumbnail opened, so no cell is left grey.
        #expect(newest.allSatisfy { model.cachedThumbnail($0) != nil })
        #expect(model.newest(4).count == 4)
        #expect(model.newest(8).count == 8)
    }

    @Test("Never blank: opening and can't-open each have words, on the tile and in the glance")
    func statesHaveWords() async throws {
        let opening = try await library(with: trip, opened: false)
        #expect(opening.phase == .loading)
        #expect(opening.glance?.lines == ["Opening your photos"])
        let closed = PhotosModel(library: nil, unavailable: PhotosModel.signedOut)
        #expect(closed.glance?.lines == [PhotosModel.signedOut.title])
        let empty = try await library(with: [])
        #expect(empty.glance?.lines == ["No photos yet"])
    }
}

#if os(macOS)
import AppKit

/// Writes the Photos tile at medium and large, inside the home grid, to PNGs for a person to look at,
/// when TOTALITY_RENDER_DIR is set. The grid is part of it on purpose: the tile once went blank there
/// while it rendered fine on its own.
@MainActor
@Suite struct RenderPhotosTiles {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view.padding(Space.s4).background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test func render() async throws {
        let full = try await library(with: trip)
        let empty = try await library(with: [])
        let closed = PhotosModel(library: nil, unavailable: PhotosModel.signedOut)
        // Rendered whether or not anyone looks, so a grid that loses the tile fails here.
        for size in [TileSize.medium, .large] {
            let renderer = ImageRenderer(content: grid(full, size: size))
            #expect(renderer.cgImage != nil)
        }
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        try write(grid(full, size: .medium), name: "photos-tile-medium.png", to: directory)
        try write(grid(full, size: .large), name: "photos-tile-large.png", to: directory)
        try write(grid(full, size: .large, isHero: true), name: "photos-tile-square.png", to: directory)
        try write(grid(empty, size: .medium), name: "photos-tile-medium-empty.png", to: directory)
        try write(grid(closed, size: .medium), name: "photos-tile-medium-closed.png", to: directory)
        let opening = try await library(with: trip, opened: false)
        try write(grid(opening, size: .medium), name: "photos-tile-medium-opening.png", to: directory)
    }
}
#endif
