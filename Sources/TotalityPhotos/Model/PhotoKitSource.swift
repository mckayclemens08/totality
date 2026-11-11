#if os(iOS)
import Foundation
import Photos

/// The iPhone's own photo library, read through PhotoKit. Only what the person allowed is ever listed:
/// with Limited access that's only the items they chose. Nothing here writes to the library, and
/// Totality never deletes from it.
public struct PhotoKitSource: SyncSource {
    public init() {}

    /// Where access stands. `.limited` still syncs, but only what was chosen (P1).
    public enum Access: Equatable, Sendable {
        case notAsked, full, limited, refused
    }

    public static var access: Access {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: .notAsked
        case .authorized: .full
        case .limited: .limited
        default: .refused
        }
    }

    /// Asks iOS, which shows its own choice of Full or Limited access.
    public static func ask() async -> Access {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return access
    }

    public func candidates() async -> [SyncCandidate] {
        guard [.full, .limited].contains(Self.access) else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let assets = PHAsset.fetchAssets(with: options)
        var found: [SyncCandidate] = []
        found.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let kind: SyncCandidate.Kind = asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .live : .photo
            found.append(SyncCandidate(id: asset.localIdentifier, created: asset.creationDate, kind: kind,
                                       duration: asset.mediaType == .video ? asset.duration : nil))
        }
        return found
    }

    public func export(_ candidate: SyncCandidate, download: Bool) async throws -> SyncExport {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.id], options: nil).firstObject else {
            throw SyncSourceError.unreadable
        }
        let resources = PHAssetResource.assetResources(for: asset)
        // The version as it is now, edits included, which is what's kept from then on (P8).
        func pick(_ edited: PHAssetResourceType, _ original: PHAssetResourceType) -> PHAssetResource? {
            resources.first { $0.type == edited } ?? resources.first { $0.type == original }
        }
        switch candidate.kind {
        case .video:
            guard let video = pick(.fullSizeVideo, .video) else { throw SyncSourceError.unreadable }
            return .video(try await write(video, download: download))
        case .live:
            guard let still = pick(.fullSizePhoto, .photo) else { throw SyncSourceError.unreadable }
            let stillFile = try await write(still, download: download)
            defer { try? FileManager.default.removeItem(at: stillFile) }
            let data = try Data(contentsOf: stillFile)
            guard let motion = pick(.fullSizePairedVideo, .pairedVideo) else { return .photo(data) }
            return .live(still: data, motion: try await write(motion, download: download))
        case .photo:
            guard let photo = pick(.fullSizePhoto, .photo) else { throw SyncSourceError.unreadable }
            let file = try await write(photo, download: download)
            defer { try? FileManager.default.removeItem(at: file) }
            return .photo(try Data(contentsOf: file))
        }
    }

    /// A plain copy in the app's temporary folder, readable only while the phone is unlocked, and named so
    /// a launch that was stopped partway clears it next time.
    private func write(_ resource: PHAssetResource, download: Bool) async throws -> URL {
        let ext = (resource.originalFilename as NSString).pathExtension
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("totality-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "dat" : ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = download
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            if (error as NSError).domain == PHPhotosErrorDomain, (error as NSError).code == PHPhotosError.networkAccessRequired.rawValue {
                throw SyncSourceError.inICloud
            }
            throw SyncSourceError.unreadable
        }
    }
}
#endif
