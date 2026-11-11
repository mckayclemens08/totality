import Foundation
import TotalityCore

/// What Totality knows about one photo, sealed with the content key. The server never sees any of it:
/// not the date, the size in pixels, the kind of file, or which blobs hold it.
public struct PhotoDetails: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let id: UUID
    /// The account it belongs to. A photo whose details name another account is never shown.
    public let owner: String
    /// The blobs in the sealed store holding the original and the thumbnail. Random, made for this photo.
    public let original: UUID
    public let thumbnail: UUID
    public let added: Date
    /// When it was taken, read from the file itself, if it says.
    public let taken: Date?
    public let width: Int
    public let height: Int
    /// The file's type, like `public.heic`.
    public let type: String
    /// The original's size before sealing.
    public let byteCount: Int

    /// What kind of item it is. Nil for a still photo, which is all step 2 made.
    public var media: Media?
    /// How long a video or a Live Photo's movement plays, in seconds.
    public var duration: Double?
    /// The blob holding a Live Photo's movement, sealed in chunks. For a video, `original` is the video.
    public var motion: UUID?
    /// The movement's size before sealing.
    public var motionByteCount: Int?

    public enum Media: String, Codable, Sendable {
        case video, live
    }

    // What the person changes. Each is content, so it's sealed with the rest (non-negotiable 2).
    public var isFavourite: Bool?
    public var caption: String?
    /// The albums it's in. An album that's gone is ignored.
    public var albums: [UUID]?
    /// When it went to Recently Deleted. It's removed for good 30 days later.
    public var trashed: Date?
    /// Raised by every change, so a server handing back an older copy is noticed.
    public var revision: Int?

    public init(
        id: UUID, owner: String, original: UUID, thumbnail: UUID, added: Date, taken: Date?,
        width: Int, height: Int, type: String, byteCount: Int
    ) {
        version = Self.currentVersion
        self.id = id
        self.owner = owner
        self.original = original
        self.thumbnail = thumbnail
        self.added = added
        self.taken = taken
        self.width = width
        self.height = height
        self.type = type
        self.byteCount = byteCount
    }

    /// The date the library sorts by.
    public var date: Date { taken ?? added }

    /// Long enough for a real caption, short enough that it can't be used to store something else.
    public static let captionLimit = 2_000

    public var favourite: Bool { isFavourite ?? false }
    public var isVideo: Bool { media == .video }
    public var isLive: Bool { media == .live && motion != nil }
    /// The sealed movie, if there is one: the video itself, or a Live Photo's movement.
    public var movie: (blob: UUID, byteCount: Int)? {
        switch media {
        case .video: (original, byteCount)
        case .live: motion.map { ($0, motionByteCount ?? 0) }
        case nil: nil
        }
    }
    public var changeCount: Int { revision ?? 0 }
    public var albumIDs: [UUID] { albums ?? [] }
}

/// An album the person made. Only its name is here: which photos are in it is in each photo's details.
public struct PhotoAlbum: Codable, Sendable, Equatable, Identifiable {
    public static let currentVersion = 1
    /// Long enough for any real name, short enough that the row can't be used to store something else.
    public static let nameLimit = 200

    public let version: Int
    public let id: UUID
    /// The account it belongs to. An album naming another account is never shown.
    public let owner: String
    public var name: String
    public let created: Date
    /// Raised by every rename, so a server handing back an older name is noticed.
    public var revision: Int?

    public init(id: UUID, owner: String, name: String, created: Date) {
        version = Self.currentVersion
        self.id = id
        self.owner = owner
        self.name = name
        self.created = created
    }

    /// A name as it's kept: trimmed, and never empty or too long.
    public static func tidy(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(nameLimit))
    }
}

/// One photo as the screens see it.
public struct PhotoItem: Identifiable, Sendable, Equatable {
    public let details: PhotoDetails
    /// Added on this device and not on the server yet.
    public let isWaiting: Bool

    public init(details: PhotoDetails, isWaiting: Bool) {
        self.details = details
        self.isWaiting = isWaiting
    }

    public var id: UUID { details.id }
    public var date: Date { details.date }
}

public enum PhotoError: Error, Equatable, Sendable {
    /// The file isn't an image this device can read.
    case notAPhoto
    /// Bigger than one photo can be.
    case tooBig
    /// Its sealed copy didn't open with this device's key.
    case cantOpen
    /// The server has no copy of it.
    case missing
    /// The library closed, because the account or the key changed.
    case closed
    /// A video longer than this version takes.
    case tooLong
    /// Another device kept changing it, so this change didn't land. Trying again usually works.
    case changedElsewhere
    /// An album name with nothing in it.
    case emptyName
}

/// Seals and opens each part of a photo. Each part has its own key purpose, and every part is tied to
/// the photo's ID, so the server can't swap a thumbnail, an original, or details between photos or
/// between parts.
struct PhotoSealer: Sendable {
    enum Part {
        case original, thumbnail, details, album, sync, googleImport

        var purpose: KeyPurpose {
            switch self {
            case .sync: .photoSync
            case .googleImport: .photoGoogleImport
            case .original: .photo
            case .thumbnail: .photoThumbnail
            case .details: .photoDetails
            case .album: .photoAlbum
            }
        }
    }

    let rootKey: ContentRootKey

    func seal(_ data: Data, _ part: Part, of photo: UUID) throws -> Data {
        try ContentCipher.seal(data, key: rootKey.objectKey(for: photo, purpose: part.purpose), objectID: photo)
    }

    func open(_ sealed: Data, _ part: Part, of photo: UUID) throws -> Data {
        do {
            return try ContentCipher.open(sealed, key: rootKey.objectKey(for: photo, purpose: part.purpose), objectID: photo)
        } catch {
            throw PhotoError.cantOpen
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Seals a movie file into `output` a chunk at a time, so it's never held in memory whole.
    func sealMovie(_ input: URL, to output: URL, of photo: UUID) throws {
        try ChunkedCipher.seal(file: input, to: output, key: rootKey.objectKey(for: photo, purpose: .photoVideo), objectID: photo)
    }

    /// Opens a sealed movie for reading in pieces. It checks the length and the first piece, so a file
    /// that's damaged, cut short, or sealed with another key is refused here, not partway through playing.
    func openMovie(_ file: URL, of photo: UUID) throws -> ChunkedCipher.Reader {
        do {
            let reader = try ChunkedCipher.Reader(file: file, key: rootKey.objectKey(for: photo, purpose: .photoVideo), objectID: photo)
            _ = try reader.read(0..<1)
            return reader
        } catch {
            throw PhotoError.cantOpen
        }
    }

    func sealDetails(_ details: PhotoDetails) throws -> Data {
        try seal(Self.encoder.encode(details), .details, of: details.id)
    }

    func sealAlbum(_ album: PhotoAlbum) throws -> Data {
        try seal(Self.encoder.encode(album), .album, of: album.id)
    }

    /// The album, only if it opens, is this album, and belongs to `account`.
    func openAlbum(_ sealed: Data, of album: UUID, account: String) throws -> PhotoAlbum {
        guard let opened = try? Self.decoder.decode(PhotoAlbum.self, from: try open(sealed, .album, of: album)),
              opened.id == album, opened.owner == account, opened.version == PhotoAlbum.currentVersion
        else { throw PhotoError.cantOpen }
        return opened
    }

    /// The details, only if they open, are this photo's, and belong to `account`.
    func openDetails(_ sealed: Data, of photo: UUID, account: String) throws -> PhotoDetails {
        guard let details = try? Self.decoder.decode(PhotoDetails.self, from: try open(sealed, .details, of: photo)),
              details.id == photo, details.owner == account, details.version == PhotoDetails.currentVersion
        else { throw PhotoError.cantOpen }
        return details
    }
}
