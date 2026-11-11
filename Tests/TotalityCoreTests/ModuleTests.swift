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

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var now: Int { lock.withLock { value } }
}

private struct Refresher: ModuleRefresher {
    let module: ModuleID
    let kinds: Set<ContentKind> = []
    let count: Count
    func refreshAhead() async { count.add() }
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

    @Test("Only modules that refresh ahead are asked to")
    func refreshers() async throws {
        let count = Count()
        let registry = try ModuleRegistry(handlers: [Refresher(module: .mail, count: count), Handler(module: .web, kinds: [])])
        #expect(registry.refreshers.map(\.module) == [.mail])
        for refresher in registry.refreshers { await refresher.refreshAhead() }
        #expect(count.now == 1)
    }

    @Test("The app's refresh runs every refresher, and one asked for meanwhile waits for it")
    @MainActor func appRefreshCoalesces() async throws {
        let count = Count()
        let refresh = AppRefresh()
        await refresh.refresh()
        #expect(count.now == 0)
        refresh.registry = try ModuleRegistry(handlers: [Refresher(module: .mail, count: count), Refresher(module: .calendar, count: count)])
        async let first: Void = refresh.refresh()
        async let second: Void = refresh.refresh()
        _ = await (first, second)
        #expect(count.now <= 4)
        #expect(count.now >= 2)
        await refresh.refresh()
        #expect(count.now >= 4)
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
        #expect(ContentKind.photoAlbum.rawValue == "photo_album")
        #expect(ContentKind.allCases.count == 17)
    }

    @Test func contentRefSurvivesEncoding() throws {
        let original = ref(.doc)
        #expect(try JSONDecoder().decode(ContentRef.self, from: JSONEncoder().encode(original)) == original)
    }
}
