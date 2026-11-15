import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Someone's public profile, as anyone signed in to Totality can see it. Everything in it is public by
/// design. The photo is never the file from the server: it's pixels this device decoded within a size
/// cap and rebuilt itself, or nil.
public struct PublicProfile: Codable, Equatable, Sendable {
    public let username: String
    public let displayName: String?
    public let bio: String?
    /// A small square JPEG made on this device by `SafeAvatar`.
    public let photo: Data?

    public init(username: String, displayName: String?, bio: String?, photo: Data?) {
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.photo = photo
    }

    /// What to call them: their chosen name, or their handle.
    public var name: String {
        guard let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return username }
        return displayName
    }

    /// Up to two letters from their name, for the disc shown when there's no photo.
    public static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "." || $0 == "-" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// Looks up public profiles by handle. Account provides it and the app hands it over through the
/// `ModuleRegistry`, so Messages can show people without importing Account.
public protocol ProfileDirectory: Sendable {
    /// Nil when there's no profile this account can see. Throws when the directory couldn't be asked.
    func profile(of username: String) async throws -> PublicProfile?
}

/// Makes another person's profile photo safe to show. The `avatars` bucket only checks the type a file
/// claims, and a client can skip the device's own rebuild, so the bytes are treated as hostile: they
/// must really be a JPEG or PNG, of a sensible size, and only a small decoded copy is ever drawn.
public enum SafeAvatar {
    /// Larger downloads are dropped before decoding. A rebuilt avatar is well under 100 KB.
    public static let maximumBytes = 2_000_000
    /// Larger images are refused without decoding, so a tiny file can't claim a huge canvas.
    public static let maximumEdge = 4096
    /// The side of the square that's kept.
    public static let side = 256

    /// A fresh square JPEG of the picture, or nil when it isn't a real, reasonably sized image.
    public static func prepare(_ data: Data) -> Data? {
        guard data.count <= maximumBytes, let type = kind(of: data) else { return nil }
        let options = [kCGImageSourceShouldCache: false, kCGImageSourceTypeIdentifierHint: type.identifier] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) as String? == type.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumEdge, height <= maximumEdge
        else { return nil }

        let longEdge = side * max(width, height) / min(width, height)
        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // A very wide or tall picture still decodes small; the square is cut from the middle.
            kCGImageSourceThumbnailMaxPixelSize: min(max(longEdge, side), side * 4),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else { return nil }
        let edge = min(scaled.width, scaled.height)
        let square = CGRect(x: (scaled.width - edge) / 2, y: (scaled.height - edge) / 2, width: edge, height: edge)
        guard let cropped = scaled.cropping(to: square) else { return nil }

        // Only the pixels go into the new file: no metadata from the original survives.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The type the first bytes prove, which is the only one trusted.
    static func kind(of data: Data) -> UTType? {
        let head = [UInt8](data.prefix(8))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        if head == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        return nil
    }
}
