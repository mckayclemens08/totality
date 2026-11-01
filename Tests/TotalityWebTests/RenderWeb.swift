#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TotalityUI
@testable import TotalityWeb

/// Writes Web's tiles and download marker to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set.
@MainActor
@Suite struct RenderWeb {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view.padding(Space.s4).background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func tile(_ model: WebModel, size: BigTileSize, height: CGFloat) -> some View {
        TileLabel(
            module: ModuleEntry.all.first { $0.id == .web }!, glance: model.glance, size: size,
            content: AnyView(WebHomeTile(model: model, size: size)), isEditing: false
        )
        .frame(width: 361, height: height)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let empty = WebModel(client: nil, vault: WebVault(store: MemoryBlobStore(), rootKey: try .generate()))
        await empty.use(account: "user-1")
        let full = WebModel(client: nil, vault: WebVault(store: MemoryBlobStore(), rootKey: try .generate()))
        await full.use(account: "user-1")
        let sites = [
            ("Lisbon - Wikipedia", "https://en.wikipedia.org/wiki/Lisbon"), ("Hacker News", "https://news.ycombinator.com"),
            ("Tram 28 timetable", "https://www.carris.pt/en/tram-28"), ("GitHub", "https://github.com"),
            ("The Rock Warrior's Way", "https://www.warriorsway.com"), ("Weather", "https://weather.gov"),
            ("Apple Developer", "https://developer.apple.com"), ("BBC News", "https://www.bbc.com/news"),
            ("Reddit", "https://www.reddit.com"), ("Maps", "https://www.openstreetmap.org"),
        ]
        for (title, address) in sites.reversed() { await full.addBookmark(title: title, url: URL(string: address)!) }
        full.open(URL(string: "https://en.wikipedia.org/wiki/Lisbon")!)
        full.current.page?.stop()

        let few = WebModel(client: nil, vault: WebVault(store: MemoryBlobStore(), rootKey: try .generate()))
        await few.use(account: "user-1")
        await few.addBookmark(title: "Lisbon - Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Lisbon")!)
        await few.addBookmark(title: "GitHub", url: URL(string: "https://github.com")!)

        for (name, model) in [("empty", empty), ("full", full), ("few", few)] {
            try write(VStack(spacing: Space.s4) {
                tile(model, size: .medium, height: 172)
                tile(model, size: .large, height: 266)
                tile(model, size: .square, height: 361)
            }, name: "web-tile-\(name).png", to: directory)
        }
        try write(HStack(spacing: Space.s4) {
            WebDownloadStatus(progress: 0)
            WebDownloadStatus(progress: 0.35)
            WebDownloadStatus(progress: 0.8)
            WebDownloadStatus(progress: nil)
        }, name: "web-marker.png", to: directory)
    }
}
#endif
