import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

@Suite struct ReaderSearchModuleTests {
    @Test("The Reader answers search with the title, the words around the match, and how to open it")
    func answers() async throws {
        let vault = try newVault()
        let note = try await vault.createNote()
        let saved = try await vault.saveNote(note.id, title: "Lisbon trip", body: "Take the tram to Belém before noon.")
        let hit = try #require(try await ReaderModule(vault: vault).search("belem").first)
        #expect(hit.module == .reader)
        #expect(hit.itemID == note.id.uuidString)
        #expect(hit.title == "Lisbon trip")
        #expect(hit.snippet == "Take the tram to Belém before noon.")
        #expect(hit.date == saved.updatedAt)
    }

    @Test("A match in the title alone has no words to show")
    func titleOnly() async throws {
        let vault = try newVault()
        let note = try await vault.createNote()
        try await vault.saveNote(note.id, title: "Lisbon trip", body: "Take the tram.")
        #expect(try await ReaderModule(vault: vault).search("lisbon").first?.snippet == nil)
    }

    @Test("An untitled note is found under the name it shows everywhere else")
    func untitled() async throws {
        let vault = try newVault()
        let note = try await vault.createNote()
        try await vault.saveNote(note.id, title: "", body: "Take the tram.")
        let item = try await vault.list().items.first { $0.id == note.id }
        #expect(try await ReaderModule(vault: vault).search("tram").first?.title == item?.displayTitle)
    }

    @Test("User 2 searching the same storage finds none of user 1's titles or text")
    func secondUser() async throws {
        let store = MemoryBlobStore()
        let first = try newVault(store: store)
        let note = try await first.createNote()
        try await first.saveNote(note.id, title: "Lisbon trip", body: "Take the tram.")
        let second = try newVault(store: store)
        #expect(try await ReaderModule(vault: first).search("lisbon tram").count == 1)
        #expect(try await ReaderModule(vault: second).search("lisbon").isEmpty)
        #expect(try await ReaderModule(vault: second).search("tram").isEmpty)
    }

    @Test("With no vault there's nothing to find")
    func noVault() async throws {
        #expect(try await ReaderModule().search("tram").isEmpty)
    }

    @Test("A search that's been replaced stops instead of reading on")
    func stops() async throws {
        let vault = try newVault()
        _ = try await vault.importFile(Data("Take the tram.".utf8), filename: "Tram.txt")
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await vault.search("tram")
        }
        await #expect(throws: CancellationError.self) { try await search.value }
    }

    @MainActor
    @Test("Typing on in the Reader's own search shows no error")
    func stoppingIsNotAFailure() async throws {
        let model = ReaderModel(vault: try newVault(), listen: ListenController(engine: FakeSpeechEngine()))
        _ = await model.newNote()
        model.query = "tram"
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.search()
        }
        await search.value
        #expect(model.notice == nil)
    }

    @Test("A thousand items, read from sealed files with nothing in memory, search within the bound")
    func speed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileBlobStore(directory: folder)
        let root = try ContentRootKey.generate()
        let writer = ReaderVault(store: store, rootKey: root)
        let body = String(repeating: "The tram climbs through Alfama past the cathedral, and the river shows between the houses. ", count: 30)
        for index in 0..<1_000 {
            let note = try await writer.createNote()
            try await writer.saveNote(note.id, title: "Day \(index) in Lisbon", body: body + (index == 777 ? "pastel de nata" : ""))
        }
        let reader = ReaderVault(store: store, rootKey: root)
        let clock = ContinuousClock()
        var hits: [ReaderSearchHit] = []
        let cold = try await clock.measure { hits = try await reader.search("nata") }
        #expect(hits.map(\.item.title) == ["Day 777 in Lisbon"])
        let warm = try await clock.measure { hits = try await reader.search("nata") }
        print("Reader search over 1,000 items: first \(cold), again \(warm)")
        #expect(hits.count == 1)
        #expect(cold < .seconds(10))
    }
}
