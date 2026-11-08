import CoreTransferable
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Turns what Apple's picker hands over into something Photos can seal. The picker gives Totality only
/// what the person chose, with no access to the rest of their library.
enum PickedMedia {
    static func pick(for item: PhotosPickerItem) -> PhotosModel.Pick {
        let types = item.supportedContentTypes
        if types.contains(where: { $0.conforms(to: .livePhoto) }) {
            return .live({ try await live(item) }, still: { try await item.loadTransferable(type: Data.self) })
        }
        if types.contains(where: { $0.conforms(to: .movie) }) {
            return .video { try await item.loadTransferable(type: PickedMovie.self)?.file }
        }
        return .photo { try await item.loadTransferable(type: Data.self) }
    }

    /// A Live Photo's still and movement, written out by Photos. Nil if it can't give them, and then the
    /// still alone is added, as a photo.
    private static func live(_ item: PhotosPickerItem) async throws -> (still: Data, motion: URL)? {
        if let live = try? await item.loadTransferable(type: PHLivePhoto.self) {
            let resources = PHAssetResource.assetResources(for: live)
            if let photo = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
               let video = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) {
                let folder = FileManager.default.temporaryDirectory
                let stillFile = folder.appendingPathComponent("totality-\(UUID().uuidString).still")
                let motionFile = folder.appendingPathComponent("totality-\(UUID().uuidString).mov")
                defer { try? FileManager.default.removeItem(at: stillFile) }
                do {
                    try await PHAssetResourceManager.default().writeData(for: photo, toFile: stillFile, options: nil)
                    try await PHAssetResourceManager.default().writeData(for: video, toFile: motionFile, options: nil)
                    return (try Data(contentsOf: stillFile), motionFile)
                } catch {
                    try? FileManager.default.removeItem(at: motionFile)
                }
            }
        }
        return nil
    }
}

/// A movie the picker copied out for Totality. It's copied again to a file of Totality's own, because the
/// picker's copy goes away when the import ends.
struct PickedMovie: Transferable {
    let file: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("totality-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(file: copy)
        }
    }
}
