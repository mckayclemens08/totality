import AVFoundation
import Foundation
import ImageIO
import TotalityCore
import UniformTypeIdentifiers

public enum MusicVaultError: Error, LocalizedError, Equatable {
    case closed
    case emptyAudio
    case fileTooLarge(limitMB: Int)
    case missingAudioBlob(UUID)

    public var errorDescription: String? {
        switch self {
        case .closed: "Sign in to open Music."
        case .emptyAudio: "That audio file appears to be empty."
        case .fileTooLarge(let limitMB): "Audio files must be \(limitMB) MB or smaller."
        case .missingAudioBlob: "That audio file isn't downloaded to this device yet."
        }
    }
}

/// Extracted local audio metadata + EXIF-stripped JPEG artwork (never raw untrusted cover bytes).
public struct ImportedAudioInfo: Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let formatLabel: String
    public let artworkJPEG: Data?

    public static func extract(from url: URL, fallbackFilename: String) async -> ImportedAudioInfo {
        let asset = AVURLAsset(url: url)
        var title = URL(fileURLWithPath: fallbackFilename).deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var rawArt: Data?

        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case .commonKeyArtist:
                    if let s = try? await item.load(.stringValue) {
                        artist = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case .commonKeyAlbumName:
                    if let s = try? await item.load(.stringValue) {
                        album = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        rawArt = data
                    }
                default:
                    break
                }
            }
        }

        let loadedDuration = (try? await asset.load(.duration).seconds) ?? 0
        let duration = loadedDuration.isFinite && loadedDuration > 0 ? loadedDuration : 0
        let ext = url.pathExtension.uppercased()
        let formatLabel = ext.isEmpty ? "Audio" : ext
        let cleanArt = rawArt.flatMap(stripAndReencodeJPEG)

        return ImportedAudioInfo(
            title: title.isEmpty ? "Untitled Track" : title,
            artist: artist,
            album: album,
            duration: duration,
            formatLabel: formatLabel,
            artworkJPEG: cleanArt
        )
    }

    private static func stripAndReencodeJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Encrypted vault for Totality Music:
/// - `catalog` stores tracks, mixed playlists, and OpenSubsonic server metadata sealed as `musicCatalog`.
/// - Uploaded audio files live chunk-sealed via `ChunkedCipher` (`KeyPurpose.musicAudio`), and cover art
///   lives sealed under `KeyPurpose.musicArt` so one can never pass as the other.
public actor MusicVault {
    public static let catalogSuffix = ".catalog"
    public static let audioSuffix = ".maudio"
    public static let artSuffix = ".mart"
    public static let maxUploadBytes = 100 << 20 // 100 MiB

    public static let sealedPurposes: [String: KeyPurpose] = [
        catalogSuffix: .musicCatalog,
        artSuffix: .musicArt,
    ]

    public static let chunkedPurposes: [String: KeyPurpose] = [
        audioSuffix: .musicAudio,
    ]

    private let store: any BlobStore
    private let cacheDirectory: URL?
    private var rootKey: ContentRootKey?
    private var catalogRecord: SealedRecordStore<MusicCatalog>?
    private var pendingCatalog: SealedRecordStore<MusicCatalog>.Pending?

    public init(store: any BlobStore, rootKey: ContentRootKey, cacheDirectory: URL? = nil) {
        self.store = store
        self.rootKey = rootKey
        self.cacheDirectory = cacheDirectory
        self.catalogRecord = SealedRecordStore(
            store: store,
            rootKey: rootKey,
            kind: .musicCatalog,
            label: "music-catalog",
            suffix: Self.catalogSuffix,
            purpose: .musicCatalog
        )
    }

    public func close() {
        rootKey = nil
        catalogRecord = nil
        pendingCatalog = nil
        wipeTemporaryPlaybackFiles()
    }

    public func loadCatalog() throws -> MusicCatalog {
        guard let catalogRecord else { throw MusicVaultError.closed }
        return (try? catalogRecord.load()) ?? MusicCatalog()
    }

    @discardableResult
    public func saveCatalog(_ value: MusicCatalog) throws -> MusicCatalog {
        guard let catalogRecord else { throw MusicVaultError.closed }
        let merged = MusicCatalog.merged(try loadCatalog(), value)
        if merged != (try? catalogRecord.load()) {
            try catalogRecord.write(merged)
        }
        return merged
    }

    /// Imports an unencrypted local audio URL by stripping/parsing metadata into the encrypted catalog
    /// and sealing the audio bytes chunked with `ChunkedCipher` + stripped JPEG artwork separately.
    public func importAudioFile(from sourceURL: URL, metadata: ImportedAudioInfo) throws -> MusicTrack {
        guard let rootKey else { throw MusicVaultError.closed }
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let byteCount = (attrs[.size] as? Int) ?? 0
        guard byteCount > 0 else { throw MusicVaultError.emptyAudio }
        guard byteCount <= Self.maxUploadBytes else { throw MusicVaultError.fileTooLarge(limitMB: 100) }

        let blobID = UUID()
        let audioKey = rootKey.objectKey(for: blobID, purpose: .musicAudio)
        let audioName = blobID.uuidString.lowercased() + Self.audioSuffix

        if let fileStore = store as? FileBlobStore {
            let destURL = try fileStore.location(of: audioName)
            try ChunkedCipher.seal(file: sourceURL, to: destURL, key: audioKey, objectID: blobID)
        } else {
            let plain = try Data(contentsOf: sourceURL)
            let sealed = try ContentCipher.seal(plain, key: audioKey, objectID: blobID)
            try store.write(sealed, as: audioName)
        }

        var artworkID: UUID?
        if let art = metadata.artworkJPEG, !art.isEmpty {
            let artUUID = UUID()
            let artKey = rootKey.objectKey(for: artUUID, purpose: .musicArt)
            let sealedArt = try ContentCipher.seal(art, key: artKey, objectID: artUUID)
            try store.write(sealedArt, as: artUUID.uuidString.lowercased() + Self.artSuffix)
            artworkID = artUUID
        }

        let now = Date()
        let track = MusicTrack(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: metadata.duration,
            formatLabel: metadata.formatLabel,
            source: .upload,
            sourceID: blobID.uuidString,
            fileExtension: sourceURL.pathExtension.lowercased(),
            artworkID: artworkID,
            byteCount: byteCount,
            isOfflineSaved: true,
            addedAt: now,
            updatedAt: now
        )

        var catalog = try loadCatalog()
        catalog.tracks.insert(track, at: 0)
        _ = try saveCatalog(catalog)
        return track
    }

    /// Decrypts a sealed track into a protected temporary file for `AVAudioFile` / `AVAudioEngine` playback.
    public func preparePlayableFile(for track: MusicTrack) throws -> URL {
        guard let rootKey else { throw MusicVaultError.closed }
        guard let blobID = UUID(uuidString: track.sourceID) else { throw MusicVaultError.missingAudioBlob(track.id) }
        let audioName = blobID.uuidString.lowercased() + Self.audioSuffix
        guard (try? store.exists(audioName)) == true else { throw MusicVaultError.missingAudioBlob(blobID) }

        let tempDir = (cacheDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent("MusicPlayback", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let ext = track.fileExtension.isEmpty ? "m4a" : track.fileExtension
        let outURL = tempDir.appendingPathComponent("\(track.id.uuidString).\(ext)")

        let key = rootKey.objectKey(for: blobID, purpose: .musicAudio)
        if let fileStore = store as? FileBlobStore {
            let sealedURL = try fileStore.location(of: audioName)
            let reader = try ChunkedCipher.Reader(file: sealedURL, key: key, objectID: blobID, keepChunks: 2)
            try reader.copyPlain(to: outURL)
        } else if let sealed = try store.read(audioName) {
            let plain = try ContentCipher.open(sealed, key: key, objectID: blobID)
            try plain.write(to: outURL, options: .atomic)
        }
        return outURL
    }

    public func loadArtwork(for track: MusicTrack) -> Data? {
        guard let rootKey, let artID = track.artworkID else { return nil }
        let name = artID.uuidString.lowercased() + Self.artSuffix
        guard let sealed = try? store.read(name) else { return nil }
        let key = rootKey.objectKey(for: artID, purpose: .musicArt)
        return try? ContentCipher.open(sealed, key: key, objectID: artID)
    }

    public func deleteUploadedBlobs(for track: MusicTrack) {
        if let blobID = UUID(uuidString: track.sourceID) {
            try? store.delete(blobID.uuidString.lowercased() + Self.audioSuffix)
        }
        if let artID = track.artworkID {
            try? store.delete(artID.uuidString.lowercased() + Self.artSuffix)
        }
    }

    public func wipeTemporaryPlaybackFiles() {
        let tempDir = (cacheDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent("MusicPlayback", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
    }
}

extension MusicVault: SyncArea {
    public nonisolated var kinds: Set<ContentKind> { [.musicCatalog] }

    public func sealedObjectIDs() throws -> [UUID] {
        guard let catalogRecord else { return [] }
        return try catalogRecord.ids()
    }

    public func sealedHash(of id: UUID) throws -> String? {
        try catalogRecord?.object(id)?.hash
    }

    public func sealedObject(_ id: UUID) throws -> SealedObject? {
        try catalogRecord?.object(id)
    }

    public func verifiedObject(_ id: UUID) throws -> SealedObject? {
        try catalogRecord?.verified(id)
    }

    public func store(_ object: SealedObject, ifLocalHash expected: String?) throws {
        guard let catalogRecord else { throw MusicVaultError.closed }
        try catalogRecord.take(object, ifLocalHash: expected, pending: &pendingCatalog)
    }

    public func removeObject(_ id: UUID, ifLocalHash expected: String) throws {}
    public func deletedObjectIDs() throws -> Set<UUID> { [] }
    public func clearDeletion(_ id: UUID) throws {}

    public func resolveConflict(local: SealedObject, remote: SealedObject) throws -> ConflictResolution {
        guard let catalogRecord else { throw MusicVaultError.closed }
        pendingCatalog = try catalogRecord.conflict(local: local, remote: remote)
        return .keepRemote
    }

    public func emptyOldTrash() throws {}
}
