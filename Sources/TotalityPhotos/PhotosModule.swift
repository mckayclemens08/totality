import Foundation
import TotalityCore

/// Photos' entry in the registry. Other modules can't attach photos yet. That comes with sharing.
public struct PhotosModule: ContentHandler {
    public let module = ModuleID.photos
    public let kinds: Set<ContentKind> = [.photo]
    private let refresh: @Sendable () async -> Void

    /// `refresh` brings the library list up to date, quietly. It never starts backing up the camera roll.
    public init(refresh: @escaping @Sendable () async -> Void = {}) {
        self.refresh = refresh
    }
}

/// The app keeps this module fresh before it's opened, through `AppRefresh`, without showing it.
extension PhotosModule: ModuleRefresher {
    public func refreshAhead() async {
        await refresh()
    }
}

/// Photos in the home search: captions and album names, on this device only.
public struct PhotosSearcher: ModuleSearcher {
    public let module = ModuleID.photos
    public let kinds: Set<ContentKind> = []
    private let find: @Sendable (String) async -> [SearchHit]

    public init(model: PhotosModel) {
        find = { query in await model.searchHits(query) }
    }

    public func search(_ query: String) async throws -> [SearchHit] { await find(query) }
}
