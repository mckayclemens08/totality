import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads a photo on the device: its size, when it was taken, and a small thumbnail. The server can't
/// make thumbnails from ciphertext, so they're made here (issue 54). The original is kept exactly as it
/// came, location and all, because it's sealed. The thumbnail carries none of the original's metadata.
public enum PhotoImport {
    /// The longest side of a thumbnail, in pixels. Sharp in a grid of three on an iPhone.
    public static let thumbnailSide = 480
    /// The biggest original taken in this version. Sealing holds it in memory a few times over, and
    /// ProRAW photos are under this.
    public static let maxBytes = 100 * 1024 * 1024

    public struct Prepared: Sendable {
        public let thumbnail: Data
        public let width: Int
        public let height: Int
        public let taken: Date?
        public let type: String
    }

    public static func prepare(_ data: Data) throws -> Prepared {
        guard data.count <= maxBytes else { throw PhotoError.tooBig }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true
        else { throw PhotoError.notAPhoto }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard var width = properties[kCGImagePropertyPixelWidth] as? Int, var height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw PhotoError.notAPhoto }
        // Orientations 5 to 8 turn the picture on its side.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        guard let thumbnail = downsampled(source, side: thumbnailSide).flatMap({ jpeg($0, quality: 0.8) }) else {
            throw PhotoError.notAPhoto
        }
        return Prepared(thumbnail: thumbnail, width: width, height: height, taken: takenDate(properties), type: type)
    }

    /// An image no bigger than `side` on its longest edge, the right way up.
    public static func image(from data: Data, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsampled(source, side: side)
    }

    static func downsampled(_ source: CGImageSource, side: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A JPEG with no metadata at all.
    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// When the camera says it was taken. Without a time zone in the file, it's read as this device's.
    static func takenDate(_ properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        guard let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFDateTime] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: text + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: text)
    }
}
