import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo ready to send: re-encoded on this device, with its small version for the chat.
public struct OutgoingPhoto: Sendable, Equatable {
    public let data: Data
    public let thumbnail: Data
    public let width: Int
    public let height: Int
    public let thumbnailWidth: Int
    public let thumbnailHeight: Int
}

public enum PhotoPrep {
    /// The longest side of a sent photo, in pixels. Plenty for a phone screen, and quick to send.
    public static let longestSide = 2048
    public static let thumbnailSide = 480

    /// Turns whatever the camera or picker gave into a plain JPEG. Drawing it afresh drops everything
    /// but the pixels, so where and when it was taken, and the camera's details, never leave the device.
    public static func prepare(_ original: Data) throws -> OutgoingPhoto {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw MessagesError.failed("That photo couldn't be opened.") }
        let (data, width, height) = try encode(source, side: longestSide, quality: 0.85)
        let (thumb, tw, th) = try encode(source, side: thumbnailSide, quality: 0.7)
        return OutgoingPhoto(data: data, thumbnail: thumb, width: width, height: height, thumbnailWidth: tw, thumbnailHeight: th)
    }

    private static func encode(_ source: CGImageSource, side: Int, quality: Double) throws -> (Data, Int, Int) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MessagesError.failed("That photo couldn't be opened.")
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MessagesError.failed("That photo couldn't be prepared.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MessagesError.failed("That photo couldn't be prepared.") }
        return (out as Data, image.width, image.height)
    }
}

/// Opened photos held in memory while a chat is open, a few at a time. (The SDK keeps its own copy in
/// the account's store, which is encrypted with the key in this device's Keychain.)
@MainActor
final class PhotoMemory {
    private var store: [String: Data] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 40) { self.limit = limit }

    subscript(key: String) -> Data? {
        get { store[key] }
        set {
            order.removeAll { $0 == key }
            guard let newValue else { store[key] = nil; return }
            store[key] = newValue
            order.append(key)
            while order.count > limit { store[order.removeFirst()] = nil }
        }
    }

    func removeAll() {
        store = [:]
        order = []
    }
}
