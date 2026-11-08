import Foundation
import TotalityCore

/// Photos' entry in the registry. Other modules can't attach photos yet. That comes with sharing.
public struct PhotosModule: ContentHandler {
    public let module = ModuleID.photos
    public let kinds: Set<ContentKind> = [.photo]

    public init() {}
}
