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

    @MainActor
    @Test("The home tile's shelf leads with what's playing, or else what was opened last")
    func frontOfShelf() async throws {
        let model = ReaderModel(vault: try newVault(), listen: ListenController(engine: FakeSpeechEngine()))
        #expect(model.frontOfShelf == nil)
        let first = try #require(await model.newNote())
        await model.saveNote(first.id, title: "Lisbon trip", body: "Take the tram.")
        let second = try #require(await model.newNote())
        await model.saveNote(second.id, title: "Porto trip", body: "Cross the bridge.")
        await model.markOpened(first.id)
        #expect(model.frontOfShelf?.id == first.id)
        await model.startListening(to: second.id)
        #expect(model.frontOfShelf?.id == second.id)
        model.listen.stop()
        await model.markOpened(first.id)
        #expect(model.frontOfShelf?.id == first.id)
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

@MainActor
@Suite struct ReadAlongListenTests {
    private let engine = FakeSpeechEngine()

    private func model() throws -> ReaderModel {
        ReaderModel(vault: try newVault(), listen: ListenController(engine: engine))
    }

    private func note(in model: ReaderModel, _ body: String) async throws -> ReaderItem {
        let note = try #require(await model.newNote())
        await model.saveNote(note.id, title: "Lisbon trip", body: body)
        return note
    }

    @Test("Read along only applies while the Listen bar is showing, so a note can always be edited")
    func appliesWithTheBar() async throws {
        let model = try model()
        let note = try await note(in: model, "Take the tram.")
        #expect(!ReaderItemView.appliesReadAlong(isOn: true, listen: model.listen))
        await model.startListening(to: note.id)
        #expect(ReaderItemView.appliesReadAlong(isOn: true, listen: model.listen))
        #expect(!ReaderItemView.appliesReadAlong(isOn: false, listen: model.listen))
        model.listen.stop()
        #expect(!ReaderItemView.appliesReadAlong(isOn: true, listen: model.listen))
    }

    @Test("Tapping a sentence with nothing playing starts Listen there")
    func starts() async throws {
        let model = try model()
        let text = "Take the tram. Walk back along the river."
        let note = try await note(in: model, text)
        await model.listen(to: note.id, from: 15, on: ListenScript(text: text))
        #expect(engine.spoken == ["Walk back along the river."])
        #expect(model.listen.current?.id == note.id)
    }

    @Test("Tapping a sentence in what's playing moves within it, without starting over")
    func moves() async throws {
        let model = try model()
        let text = "Take the tram. Walk back along the river."
        let note = try await note(in: model, text)
        await model.startListening(to: note.id)
        let playing = try #require(model.listen.current)
        await model.listen(to: note.id, from: 15, on: playing.script)
        #expect(model.listen.sentence == 1)
        #expect(model.listen.current == playing)
    }

    @Test("Tapping a sentence in another document moves Listen to it")
    func switches() async throws {
        let model = try model()
        let first = try await note(in: model, "Take the tram. Walk back.")
        let second = try await note(in: model, "Cross the bridge. Climb the hill.")
        await model.startListening(to: first.id)
        await model.listen(to: second.id, from: 18, on: ListenScript(text: "Cross the bridge. Climb the hill."))
        #expect(model.listen.current?.id == second.id)
        #expect(engine.spoken.last == "Climb the hill.")
    }

    @Test("Tapping a sentence after the note changed starts again on the new text")
    func changed() async throws {
        let model = try model()
        let note = try await note(in: model, "Take the tram. Walk back.")
        await model.startListening(to: note.id)
        let newer = "Take the tram. Walk back. Stop for coffee."
        await model.saveNote(note.id, title: "Lisbon trip", body: newer)
        await model.listen(to: note.id, from: 26, on: ListenScript(text: newer))
        #expect(model.listen.current?.script.fingerprint == ListenScript(text: newer).fingerprint)
        #expect(engine.spoken.last == "Stop for coffee.")
    }
}

@Suite struct ReaderReceiverTests {
    @Test("A page saved from another module lands in the library, sealed, and readable by Listen")
    func note() async throws {
        let store = MemoryBlobStore()
        let vault = try newVault(store: store)
        let ref = try await ReaderModule(vault: vault).receive(noteTitled: "Riding tram 28", body: "The yellow tram climbs.")
        #expect(ref.kind == .note)
        #expect(ref.preview.title == "Riding tram 28")
        #expect(String(decoding: try await vault.body(of: ref.id), as: UTF8.self) == "The yellow tram climbs.")
        for name in try store.names() {
            #expect(!String(decoding: try #require(try store.read(name)), as: UTF8.self).contains("yellow"))
        }
    }

    @Test("A file handed over is imported like any other")
    func file() async throws {
        let vault = try newVault()
        let ref = try await ReaderModule(vault: vault).receive(file: Data("Tram notes".utf8), named: "tram.txt")
        #expect(ref.kind == .file)
        #expect(try await vault.item(ref.id).kind == .file)
        #expect(String(decoding: try await vault.body(of: ref.id), as: UTF8.self) == "Tram notes")
    }

    @Test("Without a vault nothing is pretended to be saved")
    func noVault() async {
        await #expect(throws: ReaderError.notFound) { try await ReaderModule().receive(noteTitled: "A", body: "B") }
    }
}
