import Foundation
import Photos

/// Saves an original to the device's own Photos, only when the person asks. Totality asks to add, never
/// to read, so it can't see anything already there. What's saved there is out of Totality's sealing.
enum PhotoSaver {
    enum Failure: Error {
        case notAllowed
    }

    static func save(_ data: Data) async throws {
        try await allowed()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    /// A video, from a plain file the caller removes afterwards.
    static func saveVideo(_ file: URL) async throws {
        try await allowed()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
        }
    }

    /// A Live Photo, still and movement together, so it plays in Photos as it did here.
    static func saveLive(still: Data, motion: URL) async throws {
        try await allowed()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: still, options: nil)
            request.addResource(with: .pairedVideo, fileURL: motion, options: nil)
        }
    }

    private static func allowed() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
    }
}
