#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityCore
@testable import TotalityUI
@testable import TotalityReader

/// Writes the Reader's home tiles to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set, with
/// the square as a workspace (issue 127): reading, listening, and nothing saved.
@MainActor
@Suite struct RenderReaderTiles {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view.padding(Space.s4).background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// As the home page has it: the module's own tile once something's saved, else its lines.
    private func tile(_ model: ReaderModel, size: BigTileSize, height: CGFloat) -> some View {
        let glance = model.glance
        return TileLabel(
            module: ModuleEntry.all.first { $0.id == .reader }!, glance: glance, size: size,
            content: glance?.isQuiet == false ? AnyView(ReaderHomeTile(model: model, size: size)) : nil, isEditing: false
        )
        .frame(width: 361, height: height)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private func model(_ engine: FakeSpeechEngine) async throws -> ReaderModel {
        let model = ReaderModel(vault: try newVault(), listen: ListenController(engine: engine))
        for (title, body) in [
            ("Garden plan", "Plant the beans in April, after the last frost."),
            ("Lease", "Rent is due on the first of each month."),
            ("Lisbon trip", "The tram climbs the hill to the castle. From the top you can see the whole river, and the bridge in the haze."),
        ] {
            let note = try #require(await model.newNote())
            _ = await model.saveNote(note.id, title: title, body: body)
        }
        await model.load()
        return model
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let readingEngine = FakeSpeechEngine()
        let reading = try await model(readingEngine)
        reading.homePlace = "40% of the way down"
        let listeningEngine = FakeSpeechEngine()
        let listening = try await model(listeningEngine)
        await listening.playFromHome()
        listeningEngine.onWord?(10)
        let empty = ReaderModel(vault: try newVault(), listen: ListenController(engine: FakeSpeechEngine()))
        await empty.load()
        for (name, model) in [("reading", reading), ("listening", listening), ("empty", empty)] {
            try write(VStack(spacing: Space.s4) {
                tile(model, size: .medium, height: 172)
                tile(model, size: .large, height: 266)
                tile(model, size: .square, height: 361)
            }, name: "reader-tile-\(name).png", to: directory)
        }
    }
}
#endif
