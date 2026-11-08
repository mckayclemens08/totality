import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A short video ready to send: re-exported on this device, with a still for the chat.
public struct OutgoingVideo: Sendable, Equatable {
    /// A file in this app's own temporary folder. It's removed once the video is queued.
    public let file: URL
    public let thumbnail: Data
    public let seconds: Double
    public let width: Int
    public let height: Int
    public let thumbnailWidth: Int
    public let thumbnailHeight: Int
}

public enum VideoPrep {
    /// Short video only, as the spec says.
    public static let longest: Double = 60

    /// Re-exports the video as an MP4 with no metadata, so where and when it was filmed and the
    /// camera's details stay on the device, and takes a still for the chat.
    public static func prepare(_ original: URL) async throws -> OutgoingVideo {
        let asset = AVURLAsset(url: original)
        let seconds: Double
        let size: CGSize
        do {
            seconds = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MessagesError.failed("That video couldn't be opened.") }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = natural.applying(transform)
            size = CGSize(width: abs(shown.width), height: abs(shown.height))
        } catch let error as MessagesError {
            throw error
        } catch {
            throw MessagesError.failed("That video couldn't be opened.")
        }
        guard seconds.isFinite, seconds > 0 else { throw MessagesError.failed("That video couldn't be opened.") }
        guard seconds <= longest + 0.5 else { throw MessagesError.failed("Videos can be up to a minute long.") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let still = try? await generator.image(at: .zero).image else { throw MessagesError.failed("That video couldn't be opened.") }
        let (thumbnail, tw, th) = try PhotoPrep.thumbnail(of: still)

        let out = VideoFiles.folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw MessagesError.failed("That video couldn't be prepared.")
        }
        export.metadata = []
        export.metadataItemFilter = .forSharing()
        export.shouldOptimizeForNetworkUse = true
        do {
            if #available(iOS 18, macOS 15, *) {
                try await export.export(to: out, as: .mp4)
            } else {
                export.outputURL = out
                export.outputFileType = .mp4
                await export.export()
                guard export.status == .completed else { throw MessagesError.failed("That video couldn't be prepared.") }
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw MessagesError.failed("That video couldn't be prepared.")
        }
        return OutgoingVideo(
            file: out, thumbnail: thumbnail, seconds: seconds,
            width: Int(size.width), height: Int(size.height), thumbnailWidth: tw, thumbnailHeight: th
        )
    }
}

extension PhotoPrep {
    /// A small JPEG of a still, with nothing but its pixels.
    static func thumbnail(of image: CGImage) throws -> (Data, Int, Int) {
        let full = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(full, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MessagesError.failed("That video couldn't be prepared.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithData(full as CFData, nil) else {
            throw MessagesError.failed("That video couldn't be prepared.")
        }
        return try encode(source, side: thumbnailSide, quality: 0.7)
    }
}

/// Videos waiting to send, or being played, live briefly in one folder of the app's temporary space,
/// protected while the phone is locked. Each is removed when it's done with, and the folder is
/// emptied whenever Messages connects.
public enum VideoFiles {
    public static var folder: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MessagesVideo", isDirectory: true)
        #if os(iOS)
        // New files in the folder take its protection, so nothing here can be read while the phone is locked.
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        return url
    }

    /// Writes opened video bytes where the player can read them.
    static func playable(_ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return url
    }

    /// A copied or moved file keeps the protection it had before, so it's set again here.
    static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    public static func emptyFolder() {
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
    }
}

/// A video chosen in the photo picker, copied into the temporary folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = VideoFiles.folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            VideoFiles.protect(copy)
            return PickedMovie(url: copy)
        }
    }
}
