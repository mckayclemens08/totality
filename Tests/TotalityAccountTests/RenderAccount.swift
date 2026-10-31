#if os(macOS)
import AppKit
import SwiftUI
import Testing
import TotalityUI
@testable import TotalityAccount

/// Writes profile screens to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set.
@MainActor
@Suite struct RenderAccount {
    private func write(_ view: some View, name: String, to directory: String) throws {
        let renderer = ImageRenderer(content: view
            .padding(Space.s4)
            .frame(width: 393, height: 420)
            .background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test("Every icon name exists")
    func iconsExist() {
        for name in ["gearshape", "person.fill"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let full = Profile(username: "mckay_clemens", displayName: "McKay Clemens",
                           bio: "Building Totality, one module at a time.")
        let empty = Profile(username: "mckay_clemens")
        for label in ["light"] {
            for (profile, kind) in [(full, "full"), (empty, "empty")] {
                try write(VStack(spacing: Space.s4) {
                    ProfileHeader(profile: profile)
                    AccountButton(title: "Edit profile", isWorking: false) {}
                }, name: "profile-\(kind)-\(label).png", to: directory)
            }
        }
    }
}
#endif
