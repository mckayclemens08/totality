import Foundation
import Testing
@testable import TotalityCore

private struct Handler: ContentHandler {
    let module: ModuleID
    let kinds: Set<ContentKind>
}

private struct Receiver: ContentReceiver {
    let module: ModuleID
    let kinds: Set<ContentKind> = []

    private func ref() -> ContentRef {
        let id = UUID()
        return ContentRef(module: module, kind: .note, id: id, keyRef: .crk(objectID: id), preview: .init(title: "Lease"))
    }

    func attachable() async throws -> [ContentRef] { [] }
    func current(_ ref: ContentRef) async throws -> ContentRef? { ref }
    func receive(noteTitled title: String, body: String) async throws -> ContentRef { ref() }
    func receive(file data: Data, named filename: String) async throws -> ContentRef { ref() }
}

@Suite("Module contracts")
struct ModuleTests {
    private func ref(_ kind: ContentKind) -> ContentRef {
        let id = UUID()
        return ContentRef(module: .reader, kind: kind, id: id, keyRef: .crk(objectID: id), preview: .init(title: "Lease"))
    }

    @Test func resolvesByKind() throws {
        let registry = try ModuleRegistry(handlers: [Handler(module: .reader, kinds: [.doc, .note])])
        #expect(registry.handler(for: ref(.doc))?.module == .reader)
        #expect(registry.handler(for: ref(.photo)) == nil)
    }

    @Test("A module never receives from itself, and one with no receiver gets nil")
    func receivers() throws {
        let registry = try ModuleRegistry(handlers: [Receiver(module: .reader), Handler(module: .web, kinds: [])])
        #expect(registry.receiver(for: .web)?.module == .reader)
        #expect(registry.receiver(for: .reader) == nil)
    }

    @Test func rejectsTwoHandlersForOneModuleOrKind() {
        #expect(throws: ModuleRegistryError.duplicateModule(.reader)) {
            try ModuleRegistry(handlers: [Handler(module: .reader, kinds: []), Handler(module: .reader, kinds: [])])
        }
        #expect(throws: ModuleRegistryError.duplicateKind(.doc)) {
            try ModuleRegistry(handlers: [Handler(module: .reader, kinds: [.doc]), Handler(module: .photos, kinds: [.doc])])
        }
    }

    @Test("Key references round-trip through the database format", arguments: [
        KeyRef.plain,
        .crk(objectID: UUID()),
        .room(roomID: "!abc:totality.test", eventID: "$event:one"),
    ])
    func keyRefRoundTrip(ref: KeyRef) throws {
        #expect(KeyRef(rawValue: ref.rawValue) == ref)
        let encoded = try JSONEncoder().encode(ref)
        #expect(try JSONDecoder().decode(KeyRef.self, from: encoded) == ref)
    }

    @Test("Unknown or malformed key references are refused", arguments: ["", "plain", "plain:x", "crk:not-a-uuid", "mxroom:nothing", "server:1"])
    func keyRefRejects(text: String) {
        #expect(KeyRef(rawValue: text) == nil)
    }

    @Test func kindsMatchTheDatabaseEnum() {
        #expect(ContentKind.aiMemory.rawValue == "ai_memory")
        #expect(ContentKind.mailKeys.rawValue == "mail_keys")
        #expect(ContentKind.mailOutside.rawValue == "mail_outside")
        #expect(ContentKind.allCases.count == 16)
    }

    @Test func contentRefSurvivesEncoding() throws {
        let original = ref(.doc)
        #expect(try JSONDecoder().decode(ContentRef.self, from: JSONEncoder().encode(original)) == original)
    }
}
