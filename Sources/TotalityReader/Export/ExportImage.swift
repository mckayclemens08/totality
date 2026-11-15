import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image put into an export. It's decoded, shrunk to a size a page can use, and encoded again, so
/// nothing from the original file comes along: no camera details or location, and nothing a damaged
/// file could slip into the PDF or the Word file.
public struct ExportImage: @unchecked Sendable {
    /// Big enough for a full page at print quality.
    static let maxPixels = 2400
    static let maxBytes = 30 * 1024 * 1024

    let image: CGImage
    /// PNG when the image has see-through parts, JPEG otherwise.
    let data: Data
    let isPNG: Bool

    public init?(data original: Data) {
        guard original.count <= Self.maxBytes,
              let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let alpha = image.alphaInfo
        let isPNG = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let encoded = NSMutableData()
        let type = (isPNG ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(encoded, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.image = image
        self.data = encoded as Data
        self.isPNG = isPNG
    }

    /// The size on the page, in points: as drawn at 144 pixels an inch, and no larger than the space.
    func size(fitting bounds: CGSize) -> CGSize {
        let natural = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let scale = min(1, bounds.width / max(1, natural.width), bounds.height / max(1, natural.height))
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    /// An image written into the doc's own text, as `data:image/png;base64,…`.
    static func inline(_ address: String) -> Data? {
        guard let match = address.wholeMatch(of: /data:image\/(?:png|jpeg|jpg|gif|heic|webp);base64,([A-Za-z0-9+\/=\s]+)/) else { return nil }
        return Data(base64Encoded: String(match.1), options: .ignoreUnknownCharacters)
    }

    /// The name a figure's address gives a file, like `turnover` for `images/turnover.png`. Nil for an
    /// address on the internet, which export never fetches.
    static func filename(_ address: String) -> String? {
        let lowered = address.lowercased()
        guard !address.isEmpty, !lowered.contains("://"), !lowered.hasPrefix("data:"), !lowered.hasPrefix("mailto:") else { return nil }
        let last = address.split(separator: "/").last.map(String.init) ?? address
        return last.removingPercentEncoding ?? last
    }
}
