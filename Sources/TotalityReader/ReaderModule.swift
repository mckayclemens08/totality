import Foundation
import TotalityCore

/// The Reader's entry in the registry.
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

extension ReaderModule: ContentReceiver {
    public func receive(noteTitled title: String, body: String) async throws -> ContentRef {
        guard let vault else { throw ReaderError.notFound }
        let note = try await vault.createNote(title: title)
        return Self.ref(try await vault.saveNote(note.id, title: title, body: body))
    }

    public func receive(file data: Data, named filename: String) async throws -> ContentRef {
        guard let vault else { throw ReaderError.notFound }
        return Self.ref(try await vault.importFile(data, filename: filename))
    }
}

extension ReaderModule: ModuleSearcher {
    public func search(_ query: String) async throws -> [SearchHit] {
        try await vault?.search(query).map { hit in
            SearchHit(
                module: .reader, itemID: hit.item.id.uuidString, title: hit.item.displayTitle,
                detail: hit.item.detail, snippet: hit.snippet, date: hit.item.updatedAt
            )
        } ?? []
    }
}
