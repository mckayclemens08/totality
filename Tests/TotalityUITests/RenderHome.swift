#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
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
        for name in ModuleEntry.all.map(\.systemImage) + ["circle.hexagongrid", "list.bullet"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        for label in ["light"] {
            try write(HomeView { _ in }, name: "home-\(label).png", to: directory)
            // ImageRenderer draws ScrollView as blank, so this renders the rows it holds.
            let list = ZStack {
                Theme.current.bg.color
                ModuleRows(modules: ModuleEntry.all) { _ in }.padding(.horizontal, Space.s4)
            }
            try write(list, name: "list-\(label).png", to: directory)
        }
    }
}
#endif
