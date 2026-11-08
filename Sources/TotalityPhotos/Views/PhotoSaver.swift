import Foundation
import Photos

/// Saves an original to the device's own Photos, only when the person asks. Totality asks to add, never
/// to read, so it can't see anything already there. What's saved there is out of Totality's sealing.
enum PhotoSaver {
    enum Failure: Error {
        case notAllowed
    }

    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
