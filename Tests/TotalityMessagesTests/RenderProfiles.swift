#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import TotalityCore
import TotalityUI
import UniformTypeIdentifiers
@testable import TotalityMessages

/// Writes another person's profile in each of its states to PNGs for a person to look at, when
/// TOTALITY_RENDER_DIR is set: found with a photo, found without one, no profile yet, offline, loading,
/// plus the chat header and a group sender with their face.
@MainActor
@Suite struct RenderProfiles {
    private func write(_ view: some View, name: String, to directory: String, height: CGFloat = 520) throws {
        let renderer = ImageRenderer(content: view
            .frame(width: 393, height: height, alignment: .top)
            .background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// A soft two-tone picture standing in for a face, put through the same rebuild as a real download.
    private func photo() throws -> Data {
        let size = 900
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.78, green: 0.84, blue: 0.88, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0.45, green: 0.55, blue: 0.62, alpha: 1))
        context.fillEllipse(in: CGRect(x: 300, y: 420, width: 300, height: 300))
        context.fillEllipse(in: CGRect(x: 150, y: -200, width: 600, height: 520))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        CGImageDestinationFinalize(destination)
        return try #require(SafeAvatar.prepare(output as Data))
    }

    @Test func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let face = try photo()
        let ana = PublicProfile(username: "ana_ruiz", displayName: "Ana Ruiz", bio: "Climbs on Saturdays. Planning the Lisbon trip.", photo: face)
        let plain = PublicProfile(username: "mckay_test", displayName: nil, bio: nil, photo: nil)
        let states: [(String, String, PersonProfileView.Phase)] = [
            ("profile-found.png", "ana_ruiz", .found(ana)),
            ("profile-no-photo.png", "mckay_test", .found(plain)),
            ("profile-missing.png", "sam_lee", .missing),
            ("profile-offline.png", "sam_lee", .failed("Their profile didn't load. You may be offline.")),
            ("profile-loading.png", "sam_lee", .loading),
        ]
        for (name, username, phase) in states {
            try write(PersonProfileView(username: username, phase: phase, onMessage: {}, onRetry: {}), name: name, to: directory)
        }

        let theme = Theme.current
        let chat = VStack(alignment: .leading, spacing: Space.s4) {
            // The chat header: their face and name, which opens the profile.
            HStack {
                Image(systemName: "chevron.left").foregroundStyle(theme.accent.color)
                Spacer()
                HStack(spacing: Space.s2) {
                    PersonFace(photo: face, name: ana.name, diameter: Space.s6)
                    Text(ana.name).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                }
                Spacer()
                ToolbarGlyph(systemImage: "ellipsis")
            }
            // The chat list: with a photo, with initials, and a removed photo.
            ForEach([(face, "Ana Ruiz"), (nil, "mckay_test"), (nil, "Sam Lee")], id: \.1) { photo, name in
                HStack(spacing: Space.s3) {
                    PersonFace(photo: photo, name: name)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(name).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        Text("See you at 7:30").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                    Spacer()
                }
                .padding(Space.s3)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
            }
            // A group sender, tappable for their profile.
            Bubble(
                message: ChatMessage(id: "g", sender: "@ana_ruiz:usetotality.com", body: "Bring the map, I'll bring snacks.", isOwn: false, time: Date(timeIntervalSince1970: 1_794_330_000)),
                model: ChatModel(channel: FakeChannel()),
                showsSender: true, senderName: ana.name, senderPhoto: face, onOpenSender: {},
                showsSeen: false, onRetry: {}, onOpenPhoto: {}, onReply: {}, onDelete: {}
            )
        }
        .padding(Space.s4)
        try write(chat, name: "profile-in-chats.png", to: directory, height: 560)
    }
}
#endif
