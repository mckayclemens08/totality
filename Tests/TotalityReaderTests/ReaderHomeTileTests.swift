import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

/// What the Reader's home square shows (issue 127).
@MainActor
@Suite struct ReaderHomeTileTests {
    @Test("Where you are, in words")
    func whereYouAre() {
        let now = Date()
        #expect(ReaderModel.whereYouAre(ReadingPlace(spot: .pdf(page: 111), at: now)) == "Page 112")
        #expect(ReaderModel.whereYouAre(ReadingPlace(spot: .book(chapter: "ch04.xhtml", progress: 0.42), at: now)) == "42% through the chapter")
        #expect(ReaderModel.whereYouAre(ReadingPlace(spot: .doc(scroll: 0.5, cursor: 10), at: now)) == "50% of the way down")
        // The very start isn't worth saying.
        #expect(ReaderModel.whereYouAre(ReadingPlace(spot: .doc(scroll: 0, cursor: 0), at: now)) == nil)
        #expect(ReaderModel.whereYouAre(nil) == nil)
    }

    @Test("The word being said is found around where speech has reached")
    func wordAround() {
        let text = "The tram climbs the hill to the castle."
        let word = { (spoken: Int) in ReaderModel.word(in: text, at: spoken).map { String(decoding: Array(text.utf16)[$0], as: UTF16.self) } }
        #expect(word(0) == "The")
        #expect(word(5) == "tram")
        // On a space, the word before it.
        #expect(word(8) == "tram")
        #expect(word(1_000) == "castle.")
        #expect(ReaderModel.word(in: "", at: 0) == nil)
    }

    @Test("The square shows what's playing, its sentence, and two more; Listen works from it")
    func squareListens() async throws {
        let engine = FakeSpeechEngine()
        let model = ReaderModel(vault: try newVault(), listen: ListenController(engine: engine))
        var notes: [ReaderItem] = []
        for (title, body) in [
            ("Lisbon trip", "The tram climbs the hill to the castle. Then lunch by the river."),
            ("Lease", "Rent is due on the first."),
            ("Deck plans", "Wider stairs."),
            ("Garden", "Plant the beans in April."),
        ] {
            let note = try #require(await model.newNote())
            #expect(await model.saveNote(note.id, title: title, body: body))
            notes.append(note)
        }
        await model.load()
        let front = try #require(model.frontOfShelf)
        #expect(model.homeMore.count == 2)
        #expect(!model.homeMore.contains { $0.id == front.id })
        #expect(model.homeCanListen && !model.homeIsListening)
        #expect(model.homeListenLine == nil)

        await model.playFromHome()
        #expect(model.homeIsListening)
        #expect(model.listen.current?.id == front.id)
        let first = try #require(model.homeListenLine)
        #expect(!first.text.isEmpty)

        model.listen.togglePause()
        #expect(model.listen.isPaused)
        await model.playFromHome()
        #expect(!model.listen.isPaused)
        #expect(engine.resumes == 1)
    }
}
