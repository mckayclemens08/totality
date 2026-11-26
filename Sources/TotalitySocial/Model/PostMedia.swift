import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo, a video or a voice clip in a post or a story (issue 149 §2). The bytes live on Totality's own server
/// (`server/social-media/`) under the author's own folder; posts made before that kept theirs in Supabase
/// Storage's `social-media` bucket, which is still read. A public post's media are stored readable, so For
/// You can show them to anyone signed in. A Friends or Close-friends post's media are sealed on the device
/// first with a fresh key per file, and that key travels only inside the post's end-to-end encrypted Matrix
/// event.
public struct PostMedia: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case photo, audio, video }
    /// Where the bytes are kept.
    public enum Store: String, Codable, Sendable {
        /// Totality's own server, for every post's file from the move on.
        case totality
        /// Totality's own server's story shelf, where every file is deleted a day after it went up.
        case stories
    }

    public let kind: Kind
    /// `<author's account ID>/<random ID>`. It says nothing about the file.
    public let path: String
    public let size: Int
    public var width: Int?
    public var height: Int?
    /// Seconds, for audio and video.
    public var duration: Double?
    /// The AES-256-GCM key, base64, for a sealed file. Nil means the file is stored readable, which only a
    /// public post may do. It's never written to Totality's server.
    public var key: String?
    /// Nil for a file in Supabase Storage, where posts made before the move keep theirs.
    public var store: Store?

    public init(kind: Kind, path: String, size: Int, width: Int? = nil, height: Int? = nil, duration: Double? = nil, key: String? = nil,
                store: Store? = .totality) {
        self.kind = kind
        self.store = store
        self.path = path
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.key = key
    }

    public var isSealed: Bool { key != nil }

    /// The author's account ID, the first part of the path.
    public var folder: String { String(path.prefix { $0 != "/" }) }

    /// The same file as Totality's server is told about it: no key.
    public var forServer: PostMedia {
        var copy = self
        copy.key = nil
        return copy
    }
}

/// What a post may carry, matching `private.social_media_valid` and the bucket's limits, so a refusal is
/// caught before sending. The caps keep Social small on the free Oracle server (cost rule).
public enum MediaLimits {
    public static let photos = 4
    /// Longest side of a posted photo, in pixels.
    public static let photoSide = 1600
    public static let photoBytes = 1_500_000
    /// Recorded or picked audio stops at two minutes.
    public static let audioSeconds: Double = 120
    /// The per-file limit on Totality's server, as it was on the old bucket; picked audio re-encoded at the
    /// system's AAC rate fits inside it.
    public static let fileBytes = 4 * 1024 * 1024
    /// Video stops at three minutes (owner, 2026-11-17).
    public static let videoSeconds: Double = 180
    /// A video is made small on the phone first (`VideoPrep`), so three minutes usually lands at 15 to 25 MB.
    /// Matches `MAX_VIDEO` on Totality's server.
    public static let videoBytes = 40 * 1024 * 1024
    /// Sealing adds the nonce and the tag.
    public static let sealOverhead = 28

    /// The most one file of a kind may be, as stored.
    public static func most(_ kind: PostMedia.Kind) -> Int {
        (kind == .video ? videoBytes : fileBytes) + sealOverhead
    }

    static let path = try! NSRegularExpression(pattern: "^[0-9a-f-]{36}/[0-9a-f-]{36}$")

    /// Nil when this set of media is fine for a post: up to four photos, or one audio clip on its own, or
    /// one video with its cover photo, each a file of a sensible size on the post shelf, sealed exactly
    /// when the post is encrypted.
    public static func problem(_ media: [PostMedia], encrypted: Bool) -> String? {
        if media.isEmpty { return nil }
        let photos = media.filter { $0.kind == .photo }.count
        let audio = media.filter { $0.kind == .audio }.count
        let video = media.filter { $0.kind == .video }.count
        if photos > Self.photos { return "A post can hold up to \(Self.photos) photos." }
        if audio > 1 || (audio == 1 && media.count > 1) { return "A post holds photos or one audio clip, not both." }
        if video > 1 || (video == 1 && photos > 1) { return "A post holds one video and its cover." }
        if media.contains(where: { $0.store == .stories }) { return "That file belongs to a story." }
        return items(media, encrypted: encrypted)
    }

    /// Each file on its own: its size, address, sealing, key and length.
    static func items(_ media: [PostMedia], encrypted: Bool) -> String? {
        for item in media {
            if item.size <= 0 || item.size > most(item.kind) { return "One of those files is too big to post." }
            let range = NSRange(item.path.startIndex..., in: item.path)
            if path.firstMatch(in: item.path, range: range) == nil { return "One of those files has a bad address." }
            if encrypted != item.isSealed { return "That file isn't sealed the way this post needs." }
            if item.kind == .audio, let duration = item.duration, duration > audioSeconds + 1 { return "Audio is capped at two minutes." }
            if item.kind == .video {
                guard let duration = item.duration, duration <= videoSeconds + 1 else { return "Video is capped at three minutes." }
                if item.store == nil { return "That video has a bad address." }
            }
            if let key = item.key, Data(base64Encoded: key)?.count != 32 { return "That file's key isn't valid." }
        }
        return nil
    }
}

/// Sealing for Friends and Close-friends media: AES-256-GCM with a fresh random key for every file, so one
/// key opens one file and nothing else. The key is never derived from anything.
public enum MediaSeal {
    public static func seal(_ data: Data) throws -> (sealed: Data, key: String) {
        let key = SymmetricKey(size: .bits256)
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw SocialError.failed("That file couldn't be sealed.") }
        return (combined, key.withUnsafeBytes { Data($0) }.base64EncodedString())
    }

    public static func open(_ sealed: Data, key: String) throws -> Data {
        guard let raw = Data(base64Encoded: key), raw.count == 32 else { throw SocialError.failed("That file's key isn't valid.") }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: raw))
        } catch {
            throw SocialError.failed("That file couldn't be opened. It may have changed on the way.")
        }
    }
}

/// A photo or clip picked in the composer, prepared on this device and not yet sent.
public struct Attachment: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let kind: PostMedia.Kind
    public let data: Data
    public var width: Int?
    public var height: Int?
    public var duration: Double?

    public init(kind: PostMedia.Kind, data: Data, width: Int? = nil, height: Int? = nil, duration: Double? = nil) {
        self.kind = kind
        self.data = data
        self.width = width
        self.height = height
        self.duration = duration
    }

    public var contentType: String {
        switch kind {
        case .photo: "image/jpeg"
        case .audio: "audio/mp4"
        case .video: "video/mp4"
        }
    }

    /// A photo from the picker, drawn afresh as a JPEG no bigger than the cap. Redrawing keeps only the
    /// pixels, so where and when it was taken and the camera's details never leave the device.
    public static func photo(_ original: Data) throws -> Attachment {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw SocialError.failed("That photo couldn't be opened.")
        }
        for (side, quality) in [(MediaLimits.photoSide, 0.8), (MediaLimits.photoSide, 0.6), (1200, 0.6)] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { break }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { break }
            if out.length <= MediaLimits.photoBytes {
                return Attachment(kind: .photo, data: out as Data, width: image.width, height: image.height)
            }
        }
        throw SocialError.failed("That photo is too big to post.")
    }
}

/// "1:38" for a clip's length or position.
public enum ClipTime {
    public static func text(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
