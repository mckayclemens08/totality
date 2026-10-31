import Foundation
import TotalityCore

/// The Reader's entry in the registry. `doc` waits for rich documents (proposal §11-M).
public struct ReaderModule: ContentProvider {
    public let module = ModuleID.reader
    public let kinds: Set<ContentKind> = [.note, .file]
    private let vault: ReaderVault?

    public init(vault: ReaderVault? = nil) {
        self.vault = vault
    }

    public func attachable() async throws -> [ContentRef] {
        try await vault?.list().items.map(Self.ref) ?? []
    }

    public func current(_ ref: ContentRef) async throws -> ContentRef? {
        guard let vault else { return nil }
        do {
            return Self.ref(try await vault.item(ref.id))
        } catch ReaderError.notFound {
            return nil
        }
    }

    private static func ref(_ item: ReaderItem) -> ContentRef {
        ContentRef(
            module: .reader, kind: item.kind == .note ? .note : .file, id: item.id,
            keyRef: .crk(objectID: item.id), preview: .init(title: item.displayTitle)
        )
    }
}
