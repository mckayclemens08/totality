import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The part of a video to keep, in seconds, never longer than Social allows.
public struct TrimRange: Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var length: Double { max(0, end - start) }

    /// Kept inside the video and at most three minutes long. With no sensible end, the first three minutes.
    public static func clamped(start: Double, end: Double, length total: Double) -> TrimRange {
        let total = total.isFinite ? max(0, total) : 0
        let start = min(max(0, start.isFinite ? start : 0), total)
        var end = end.isFinite ? min(max(end, start), total) : total
        if end <= start { end = total }
        end = min(end, start + MediaLimits.videoSeconds)
        return TrimRange(start: start, end: end)
    }
}

/// Makes a picked video small enough to post, on this iPhone (issue 149 §2): the trimmed part re-encoded as
/// H.264 at about 540p, or lower if that's still over the limit, with a cover photo from its first frame.
/// Re-encoding keeps only the picture and sound, so where and when it was filmed and the camera's details
/// never leave the phone.
public enum VideoPrep {
    public struct Prepared: Sendable {
        public let video: Attachment
        public let cover: Attachment
    }

    public static func length(of url: URL) async throws -> Double {
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw SocialError.failed("That video couldn't be opened.") }
        return seconds
    }

    public static func prepare(_ url: URL, keeping range: TrimRange) async throws -> Prepared {
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        let keep = TrimRange.clamped(start: range.start, end: range.end, length: total)
        guard keep.length > 0.3 else { throw SocialError.refused("Keep at least a moment of the video.") }
        let cover = try await coverPhoto(asset, at: keep.start)
        let timeRange = CMTimeRange(start: CMTime(seconds: keep.start, preferredTimescale: 600),
                                    duration: CMTime(seconds: keep.length, preferredTimescale: 600))
        for preset in [AVAssetExportPreset960x540, AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality] {
            guard let data = try? await export(asset, preset: preset, range: timeRange) else { continue }
            if data.count <= MediaLimits.videoBytes {
                let video = Attachment(kind: .video, data: data, width: cover.width, height: cover.height, duration: keep.length)
                return Prepared(video: video, cover: cover)
            }
        }
        throw SocialError.refused("That video is too big to post, even made smaller. Keep a shorter part of it.")
    }

    private static func export(_ asset: AVURLAsset, preset: String, range: CMTimeRange) async throws -> Data {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw SocialError.failed("That video couldn't be made smaller.") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        session.outputURL = out
        session.outputFileType = .mp4
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in session.exportAsynchronously { done.resume() } }
        guard session.status == .completed else { throw SocialError.failed("That video couldn't be made smaller.") }
        return try Data(contentsOf: out)
    }

    /// The frame at the start of the kept part, drawn afresh as a photo the way picked photos are.
    private static func coverPhoto(_ asset: AVURLAsset, at seconds: Double) async throws -> Attachment {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: MediaLimits.photoSide, height: MediaLimits.photoSide)
        let image: CGImage
        do {
            image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        } catch {
            throw SocialError.failed("That video couldn't be opened.")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SocialError.failed("That video couldn't be opened.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SocialError.failed("That video couldn't be opened.") }
        return try Attachment.photo(out as Data)
    }
}
