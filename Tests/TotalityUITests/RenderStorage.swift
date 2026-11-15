#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityCore
@testable import TotalityUI

/// Writes settings' Storage section in each state to a PNG for a person to look at, when
/// TOTALITY_RENDER_DIR is set: plenty of room, nearly full, almost full, offline, loading and an error.
@MainActor
@Suite struct RenderStorage {
    @Test func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let gigabyte = 1_000_000_000
        let theme = Theme.current
        let states: [(String, StorageMeter)] = [
            ("Plenty of room", .current(StorageQuota(used: 4_200_000_000, limit: 20 * gigabyte))),
            ("Nearly full", .current(StorageQuota(used: 16_800_000_000, limit: 20 * gigabyte))),
            ("Almost full", .current(StorageQuota(used: 19_400_000_000, limit: 20 * gigabyte))),
            ("Offline", .lastKnown(StorageQuota(used: 4_200_000_000, limit: 20 * gigabyte), at: Date(timeIntervalSince1970: 1_794_330_000))),
            ("Loading", .loading),
            ("Error", .failed("This couldn't be read. It'll try again shortly.")),
        ]
        let page = VStack(alignment: .leading, spacing: Space.s5) {
            Text("Storage").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                StorageBar(title: state.0, meter: state.1)
            }
            StorageBar(title: "Mailbox", meter: .current(StorageQuota(used: 120_000_000, limit: gigabyte)))
            StorageBreakdown(parts: [
                StoragePart(name: "Photos", bytes: 3_900_000_000),
                StoragePart(name: "Reader", bytes: 240_000_000),
                StoragePart(name: "Mail", bytes: 118_000_000),
            ])
        }
        .padding(Space.s4)
        .frame(width: 393, height: 900, alignment: .top)
        .background(theme.bg.color)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("storage-states.png"))
    }
}
#endif
