import Foundation
import TotalityCore
import TotalityMail
import TotalityPhotos

/// Gives settings' storage bars their numbers. The app reads them, so Account doesn't need to know
/// about Photos or Mail: the sealed store and the mailbox each say how full they are, and this device
/// counts each module's share from what it already holds.
@MainActor
enum StorageSetup {
    /// Nil when the build has no backend settings.
    static func makeModel(photos: @escaping @MainActor @Sendable () -> PhotosModel?) -> StorageModel? {
        guard let token = AccountSetup.searchToken, let account = AccountSetup.accountID else { return nil }
        let sealed = SealedStoreClient(token: token)
        let mail = MailServerClient(token: token)
        return StorageModel(sources: .init(
            account: account,
            sealed: {
                let usage = try await sealed.usage()
                return StorageQuota(used: usage.used, limit: usage.limit)
            },
            mailbox: {
                do {
                    let list = try await mail.list()
                    return StorageQuota(used: list.used, limit: list.limit)
                } catch MailServerError.offline {
                    throw StorageReadError.offline
                }
            },
            parts: { @MainActor in
                var photoBytes: Int?
                if let model = photos() { photoBytes = photoShare(model) }
                async let reader = folderSize("Reader")
                async let mailbox = folderSize("Mail")
                var parts: [StoragePart] = []
                if let photoBytes { parts.append(StoragePart(name: "Photos", bytes: photoBytes)) }
                parts.append(StoragePart(name: "Reader", bytes: await reader))
                parts.append(StoragePart(name: "Mail", bytes: await mailbox))
                return parts
            }
        ))
    }

    /// What Photos has on the server: every photo and video that finished uploading, at the size it was
    /// when added. Nil until Photos has opened on this device.
    private static func photoShare(_ model: PhotosModel) -> Int? {
        guard model.phase == .ready else { return nil }
        return model.items.lazy.filter { !$0.isWaiting }.reduce(0) { $0 + $1.details.byteCount }
    }

    /// The sealed copy a module keeps on this device, which is what it syncs.
    private nonisolated static func folderSize(_ name: String) async -> Int {
        await Task.detached(priority: .utility) {
            guard let base = try? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("Totality/\(name)", isDirectory: true),
                let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            else { return 0 }
            var total = 0
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
            }
            return total
        }.value
    }
}

/// Holds whichever Photos is current, since the app swaps it when the account or key changes.
@MainActor
final class CurrentPhotos {
    weak var model: PhotosModel?
}
