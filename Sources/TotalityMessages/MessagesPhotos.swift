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

    static func encode(_ source: CGImageSource, side: Int, quality: Double) throws -> (Data, Int, Int) {
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

/// A group photo, redrawn small and square-ish, with nothing but its pixels.
public struct GroupPhoto: Sendable, Equatable {
    public let data: Data
    public let width: Int
    public let height: Int

    public static let side = 512

    public static func prepare(_ original: Data) throws -> GroupPhoto {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw MessagesError.failed("That photo couldn't be opened.")
        }
        let (data, width, height) = try PhotoPrep.encode(source, side: side, quality: 0.8)
        return GroupPhoto(data: data, width: width, height: height)
    }

    /// Someone else's group photo, drawn afresh at a small size so nothing odd in it reaches the screen.
    static func small(_ downloaded: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(downloaded as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        return try? PhotoPrep.encode(source, side: 160, quality: 0.8).0
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
