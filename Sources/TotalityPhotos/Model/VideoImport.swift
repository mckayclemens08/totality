import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Reads a video on the device: how long it is, its size in pixels, when it was taken, and a thumbnail
/// from its first moments. The video itself is never read whole: it's sealed from its file in chunks.
public enum VideoImport {
    /// Ten minutes, as the owner agreed (issue 54, decision 5).
    public static let maxDuration: Double = 10 * 60
    /// Far more than ten minutes of 4K from an iPhone, and under the sealed store's 5 GB for one blob.
    public static let maxBytes = 4 * 1024 * 1024 * 1024

    public struct Prepared: Sendable {
        public let thumbnail: Data
        public let width: Int
        public let height: Int
        public let taken: Date?
        public let duration: Double
        public let type: String
        public let byteCount: Int
    }

    public static func prepare(_ file: URL, maxDuration: Double = maxDuration) async throws -> Prepared {
        let byteCount = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard byteCount > 0 else { throw PhotoError.notAPhoto }
        guard byteCount <= maxBytes else { throw PhotoError.tooBig }
        let asset = AVURLAsset(url: file)
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw PhotoError.notAPhoto
        }
        guard let track = tracks.first, duration.isNumeric, duration.seconds > 0 else { throw PhotoError.notAPhoto }
        guard duration.seconds <= maxDuration + 0.5 else { throw PhotoError.tooLong }
        let (size, transform) = (try? await track.load(.naturalSize, .preferredTransform)) ?? (.zero, .identity)
        let turned = size.applying(transform)
        let width = Int(abs(turned.width).rounded())
        let height = Int(abs(turned.height).rounded())
        guard width > 0, height > 0 else { throw PhotoError.notAPhoto }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: PhotoImport.thumbnailSide, height: PhotoImport.thumbnailSide)
        let moment = CMTime(seconds: min(0.5, duration.seconds / 2), preferredTimescale: 600)
        guard let frame = try? await generator.image(at: moment).image,
              let thumbnail = PhotoImport.jpeg(frame, quality: 0.8)
        else { throw PhotoError.notAPhoto }

        let taken = try? await asset.load(.creationDate)?.load(.dateValue)
        let type = UTType(filenameExtension: file.pathExtension)?.identifier ?? UTType.movie.identifier
        return Prepared(
            thumbnail: thumbnail, width: width, height: height, taken: taken ?? nil, duration: duration.seconds,
            type: type, byteCount: byteCount
        )
    }

    /// How long a movie plays, for a Live Photo's movement, which has no limit of its own beyond a few seconds.
    static func duration(of file: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: file).load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }
}
