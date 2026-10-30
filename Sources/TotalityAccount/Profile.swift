import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What other people see. All of it is public by design, so none of it is encrypted.
public struct Profile: Equatable, Sendable {
    /// Both match the constraints on `profiles`.
    public static let maximumNameLength = 50
    public static let maximumBioLength = 160

    public let username: String
    public var displayName: String?
    public var bio: String?
    public var avatarURL: URL?

    public init(username: String, displayName: String? = nil, bio: String? = nil, avatarURL: URL? = nil) {
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.avatarURL = avatarURL
    }
}

/// Rebuilds a chosen picture as a small square JPEG. A photo can carry where and when it was taken,
/// and the result is public, so only the pixels survive.
enum ProfilePhoto {
    static let side = 512

    static func prepare(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }

        // The short edge sets the size, so the centre crop still fills the square.
        let scaledLongEdge = side * max(width, height) / min(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(scaledLongEdge, side),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let edge = min(scaled.width, scaled.height)
        let square = CGRect(x: (scaled.width - edge) / 2, y: (scaled.height - edge) / 2, width: edge, height: edge)
        guard let cropped = scaled.cropping(to: square) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
