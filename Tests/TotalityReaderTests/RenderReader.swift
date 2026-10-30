#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityUI
@testable import TotalityReader

/// Writes Reader screens to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set.
@MainActor
@Suite struct RenderReader {
    private func write(_ view: some View, scheme: ColorScheme, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .frame(width: 393, height: 760)
            .background(Theme.current(scheme).bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test("Every icon name exists")
    func iconsExist() {
        let names = [
            "note.text", "doc", "book", "magnifyingglass", "exclamationmark.triangle", "lock.slash",
            "doc.questionmark", "headphones", "plus", "square.and.pencil", "square.and.arrow.down",
            "books.vertical", "gobackward", "goforward", "play.fill", "pause.fill", "xmark",
            "person.wave.2", "trash", "text.badge.plus",
        ]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    private func item(_ title: String, kind: ReaderItem.Kind = .note) -> ReaderItem {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        return ReaderItem(id: UUID(), kind: kind, title: title, collection: nil, mime: nil, byteCount: 0,
                          createdAt: date, updatedAt: date, listenPosition: 0)
    }

    @Test func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let listen = ListenController(engine: FakeSpeechEngine())
        listen.play(try #require(ListenTrack(
            id: UUID(), title: "The Rock Warrior's Way",
            text: "Climbing is a mental game. Most falls happen in the head first. Commit to the move."
        )))
        listen.skip(by: 1)
        for (scheme, label) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            // ImageRenderer draws List and ScrollView as blank, so this renders what they hold.
            let rows = VStack(alignment: .leading, spacing: Space.s3) {
                ReaderRow(item: item("Climbing team schedule"), snippet: nil)
                ReaderRow(item: item("The Rock Warrior's Way", kind: .file), snippet: "…most falls happen in the head first, so commit to the move…")
                ReaderRow(item: item(""), snippet: nil)
                Spacer()
                ListenBar(listen: listen)
            }
            .padding(Space.s4)
            try write(rows, scheme: scheme, name: "reader-rows-\(label).png", to: directory)
            let empty = ReaderMessage(
                systemImage: "book",
                title: "Nothing here yet",
                detail: "Write a note, or import a PDF or text file. Everything is encrypted on this device before it's stored."
            )
            try write(empty, scheme: scheme, name: "reader-empty-\(label).png", to: directory)
        }
    }
}
#endif
