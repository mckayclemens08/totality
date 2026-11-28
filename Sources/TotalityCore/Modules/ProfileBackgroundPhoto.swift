import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rebuilds a selected profile background from pixels so the uploaded JPEG carries no source metadata.
public enum ProfileBackgroundPhoto {
    public static let aspectRatio: CGFloat = 4.0 / 3.0
    public static let inputLimit = 20 * 1024 * 1024
    public static let targetBytes = 1024 * 1024
    public static let outputLimit = 2 * 1024 * 1024
    public static let maximumZoom: CGFloat = 3
    private static let width = 1600
    private static let height = 1200

    public static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= inputLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .image) == true
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: width * 2,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Position is measured from the left and top, from zero to one along the available travel.
    public static func cropRect(in size: CGSize, position: CGPoint, zoom: CGFloat) -> CGRect {
        let scale = zoom.isFinite ? min(max(zoom, 1), maximumZoom) : 1
        let cropWidth = min(size.width, size.height * aspectRatio) / scale
        let cropHeight = cropWidth / aspectRatio
        let x = position.x.isFinite ? min(max(position.x, 0), 1) : 0.5
        let y = position.y.isFinite ? min(max(position.y, 0), 1) : 0.5
        return CGRect(x: (size.width - cropWidth) * x, y: (size.height - cropHeight) * y,
                      width: cropWidth, height: cropHeight)
    }

    public static func prepare(_ image: CGImage, position: CGPoint, zoom: CGFloat) -> Data? {
        let size = CGSize(width: image.width, height: image.height)
        let crop = cropRect(in: size, position: position, zoom: zoom).integral
        guard let cropped = image.cropping(to: crop),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { return nil }

        var fallback: Data?
        for quality in [0.88, 0.76, 0.64, 0.52, 0.40] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, rendered,
                                       [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= targetBytes { return output as Data }
            if output.length <= outputLimit { fallback = output as Data }
        }
        return fallback
    }
}

/// Signed-in profile background access shared by Social and Account.
public protocol ProfileBackgroundStore: Sendable {
    func ownBackgroundKey() async throws -> String?
    func backgroundPhoto(_ key: String) async throws -> Data
    func updateBackground(_ jpeg: Data?, replacing previous: String?) async throws -> String?
}
