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
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view
            .frame(width: 393, height: 760)
            .background(Theme.current.bg.color))
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
            "person.wave.2", "trash", "text.line.first.and.arrowtriangle.forward", "arrow.down.to.line", "text.badge.plus", "circle.hexagongrid", "iphone",
            "doc.text", "doc.richtext", "book.closed", "doc.plaintext", "folder", "folder.badge.plus",
            "folder.badge.questionmark", "arrow.up.arrow.down", "list.bullet", "list.number",
            "square.grid.2x2", "chevron.right", "arrow.uturn.backward", "bold", "italic", "link", "checklist", "text.quote",
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
        for label in ["light"] {
            // ImageRenderer draws List and ScrollView as blank, so this renders what they hold.
            let rows = VStack(alignment: .leading, spacing: Space.s3) {
                ReaderRow(item: item("Climbing team schedule"), snippet: nil)
                ReaderRow(item: item("The Rock Warrior's Way", kind: .file), snippet: "…most falls happen in the head first, so commit to the move…")
                ReaderRow(item: item(""), snippet: nil)
                Spacer()
                ListenBar(listen: listen)
            }
            .padding(Space.s4)
            try write(rows, name: "reader-rows-\(label).png", to: directory)
            let empty = ReaderMessage(
                systemImage: "book",
                title: "Nothing here yet",
                detail: "Write a note, or import a PDF or text file. Everything is encrypted before it's stored, and can't be recovered on a new device yet."
            )
            try write(empty, name: "reader-empty-\(label).png", to: directory)
            let writing = VStack(spacing: Space.s4) {
                ConversionNotice(onConfirm: {}, onShowOriginal: {})
                ReaderMessage(
                    systemImage: "exclamationmark.triangle", title: "The writing page didn't start",
                    detail: "The writing page couldn't be shut off from the internet, so it didn't open."
                )
                WritingFormatBar(controller: WritingEditorController())
            }
            .padding(.top, Space.s4)
            try write(writing, name: "writing-states-\(label).png", to: directory)
            var counts = WritingStats()
            counts.words = 8_412
            counts.section = 1_306
            counts.selection = 48
            let goals = WritingGoals(dailyTarget: 750, day: "2026-11-13", written: 412)
            let tools = VStack(alignment: .leading, spacing: Space.s4) {
                WritingFindBar(controller: WritingEditorController(), onClose: {})
                WritingCountsLine(stats: counts, docTarget: 80_000, goals: goals)
                WritingOutline(headings: [], onJump: { _ in }, onFold: { _ in })
                    .frame(height: 260)
            }
            .padding(.top, Space.s4)
            try write(tools, name: "writing-tools-\(label).png", to: directory)

            let essay = item("The Tragic Hero in Macbeth")
            let saved = Date(timeIntervalSince1970: 1_793_000_000)
            let links = VStack(alignment: .leading, spacing: Space.s4) {
                BacklinkRow(link: .init(
                    item: item("Act one notes"),
                    snippet: "The letter scene is argued in the essay, and the witches get their own page.", count: 2
                ))
                BacklinkRow(link: .init(item: item("Seminar questions"), snippet: "Is Macbeth a tragic hero, or only a tyrant? See the essay.", count: 1))
                Divider()
                VersionRow(version: .init(id: UUID(), savedAt: saved, title: essay.title, words: 1_284, byteCount: 7_900), current: essay)
                VersionRow(version: .init(id: UUID(), savedAt: saved.addingTimeInterval(-86_400), title: "Macbeth draft", words: 912, byteCount: 5_600), current: essay)
                Spacer()
            }
            .padding(Space.s4)
            try write(links, name: "writing-links-rows-\(label).png", to: directory)
            let linkStates = VStack(spacing: Space.s4) {
                ProgressView("Looking through your docs")
                ReaderMessage(
                    systemImage: "link", title: "Nothing links here yet",
                    detail: "Type [[The Tragic Hero in Macbeth]] in another doc, or use Link to a doc in its format bar, and it shows up here."
                )
                ReaderMessage(
                    systemImage: "clock.arrow.circlepath", title: "No earlier versions yet",
                    detail: "A version is kept each time you stop writing for a moment, and when you close the doc. They're sealed, and stay on this device."
                )
                ReaderMessage(systemImage: "lock.slash", title: "Versions didn't open", detail: "They may have been damaged, or made under another key.")
            }
            .padding(.top, Space.s4)
            try write(linkStates, name: "writing-links-states-\(label).png", to: directory)
        }
    }
}
#endif
