#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityCore
@testable import TotalityUI

/// Writes the home screen to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set.
@MainActor
@Suite struct RenderHome {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view
            .frame(width: 393, height: 760))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test("Every icon name exists")
    func iconsExist() {
        for name in ModuleEntry.all.map(\.systemImage) + ["magnifyingglass", "ellipsis", "checkmark", "circle.hexagongrid", "square.grid.2x2"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let glances: [ModuleID: ModuleGlance] = [
            .reader: ModuleGlance(lines: ["Listening to The Lease", "Tax notes 2026", "Trail map", "Wedding toast", "12 items"]),
            .calendar: ModuleGlance(lines: ["Dentist, 3:00 PM", "3 things today", "All day: Sam's birthday", "6:30 PM Dinner with Ana"]),
        ]
        var layout = HomeLayout(modules: ModuleEntry.all.map(\.id))
        func grid(_ layout: HomeLayout, isEditing: Bool) -> some View {
            // ImageRenderer draws ScrollView as blank, so this renders the grid it holds.
            ZStack(alignment: .top) {
                Theme.current.bg.color
                BentoGrid(
                    layout: .constant(layout), modules: ModuleEntry.all, glances: glances, width: 361,
                    isEditing: .constant(isEditing), onOpen: { _ in }
                )
                .padding(.top, Space.s4)
            }
        }
        try write(grid(layout, isEditing: false), name: "bento.png", to: directory)
        try write(grid(layout, isEditing: true), name: "bento-edit.png", to: directory)
        layout.makeHero(.calendar)
        try write(grid(layout, isEditing: false), name: "bento-hero.png", to: directory)
    }
}
#endif
