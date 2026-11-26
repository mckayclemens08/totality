import CoreGraphics
import Foundation
import TotalityCore

/// Photos answers the shared chooser, so other modules can ask for photos without importing this one.
extension PhotosModel: PhotoChoosing {
    public var unavailableReason: String? {
        switch phase {
        case .unavailable(let title, _): return title
        case .loading, .ready: return photoLibrary == nil ? "Photos isn't open yet." : nil
        }
    }

    public var choices: [ChoosablePhoto] {
        items(in: .library).map {
            ChoosablePhoto(id: $0.id, date: $0.date, isVideo: $0.details.isVideo, duration: $0.details.duration)
        }
    }

    public func refreshChoices() async {
        // Only the first open: the app already keeps the list fresh, and this never starts a backup.
        if phase == .loading { await load() }
    }

    public func thumbnail(of id: UUID) async -> CGImage? {
        guard let item = item(withID: id) else { return nil }
        return await thumbnail(item)
    }

    public func photo(_ id: UUID) async throws -> Data {
        guard let item = item(withID: id) else { throw PhotoError.missing }
        return try await original(item)
    }

    public func video(_ id: UUID) async throws -> URL {
        guard let item = item(withID: id) else { throw PhotoError.missing }
        return try await exportMovie(item)
    }

    public func keep(_ media: [ChosenMedia]) async {
        var picks: [Pick] = []
        for one in media {
            switch one {
            case .photo(let data, _):
                picks.append(.photo { data })
            case .video(let url):
                // Photos removes the files it's handed once they're sealed, so it gets its own copy.
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("totality-\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil {
                    picks.append(.video { copy })
                }
            }
        }
        await add(picks: picks)
    }

    private func item(withID id: UUID) -> PhotoItem? {
        items.first { $0.id == id }
    }
}
