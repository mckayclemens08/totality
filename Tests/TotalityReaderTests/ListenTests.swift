import Foundation
import Testing
@testable import TotalityReader

@Suite struct ListenScriptTests {
    @Test func splitsIntoSentencesWithTrueOffsets() {
        let text = "First sentence. Second one! Third?"
        let script = ListenScript(text: text)
        #expect(script.sentences.map(\.text) == ["First sentence.", "Second one!", "Third?"])
        let utf16 = Array(text.utf16)
        for sentence in script.sentences {
            let slice = utf16[sentence.offset..<(sentence.offset + sentence.text.utf16.count)]
            #expect(String(decoding: slice, as: UTF16.self) == sentence.text)
        }
    }

    @Test("Offsets stay true after emoji, which take two UTF-16 units")
    func offsetsAfterEmoji() {
        let script = ListenScript(text: "Send 🧗 now. Next sentence.")
        #expect(script.sentences.last?.offset == "Send 🧗 now. ".utf16.count)
    }

    @Test func blankTextHasNoSentences() {
        #expect(ListenScript(text: " \n\n  ").sentences.isEmpty)
    }

    @Test func longUnpunctuatedTextIsCutAtSpaces() {
        let text = String(repeating: "word ", count: 500)
        let script = ListenScript(text: text)
        #expect(script.sentences.count > 1)
        #expect(script.sentences.allSatisfy { $0.text.count <= ListenScript.maxSentenceLength })
        #expect(script.sentences.allSatisfy { $0.text.hasPrefix("word") && $0.text.hasSuffix("word") })
    }

    @Test func offsetFindsItsSentence() {
        let script = ListenScript(text: "One here. Two here. Three here.")
        #expect(script.index(at: 0) == 0)
        #expect(script.index(at: 9) == 0)
        #expect(script.index(at: 10) == 1)
        #expect(script.index(at: 1000) == 2)
    }

    @Test("Progress moves inside a sentence, and never past where the next one starts")
    func progressInsideASentence() {
        let script = ListenScript(text: "One here. Two here. Three here.")
        #expect(script.progress(at: 0, spoken: 4) == 4.0 / 31.0)
        #expect(script.progress(at: 1) == 10.0 / 31.0)
        #expect(script.progress(at: 1, spoken: 4) == 14.0 / 31.0)
        #expect(script.progress(at: 0, spoken: 1000) == 9.0 / 31.0)
        #expect(script.progress(at: 0, spoken: -4) == 0)
    }
}

@MainActor
@Suite struct ListenControllerTests {
    private func track(_ text: String = "One. Two. Three.", startOffset: Int = 0) throws -> ListenTrack {
        try #require(ListenTrack(id: UUID(), title: "Track", text: text, startOffset: startOffset))
    }

    @Test func playsSentencesInOrderAndClearsWhenDone() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        var positions: [Int] = []
        listen.onPosition = { _, offset in positions.append(offset) }
        listen.play(try track())
        engine.onFinish?()
        engine.onFinish?()
        #expect(engine.spoken == ["One.", "Two.", "Three."])
        engine.onFinish?()
        #expect(listen.current == nil)
        #expect(positions == [0, 5, 10, 0])
    }

    @Test("A word moves the bar, the way a long PDF needs, and the saved position stays on a sentence")
    func wordsMoveTheBar() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        var positions: [Int] = []
        listen.onPosition = { _, offset in positions.append(offset) }
        let text = String(repeating: "A sentence of a few plain words. ", count: 900)
        let played = try track(text)
        listen.play(played)
        #expect(listen.progress == 0)
        engine.onWord?(11)
        #expect(listen.progress == 11.0 / Double(played.script.length))
        engine.onWord?(23)
        #expect(listen.progress == 23.0 / Double(played.script.length))
        listen.stop()
        #expect(positions == [0, 0])
    }

    @Test("The next sentence starts from its own beginning, however far the last one got")
    func wordsResetWithEachSentence() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        let played = try track("One two three. Four five six. Seven.")
        listen.play(played)
        engine.onWord?(8)
        engine.onFinish?()
        #expect(listen.progress == played.script.progress(at: 1))
        engine.onWord?(5)
        listen.skip(by: -1)
        #expect(listen.progress == 0)
    }

    @Test func theCountSaysWhichSentenceThisIs() {
        #expect(ListenBar.label(forSentence: 0, of: 3) == "1 of 3")
        #expect(ListenBar.label(forSentence: 13, of: 875) == "14 of 875")
    }

    @Test func resumesFromTheSavedPosition() throws {
        let engine = FakeSpeechEngine()
        ListenController(engine: engine).play(try track(startOffset: 6))
        #expect(engine.spoken == ["Two."])
    }

    @Test func queueAdvancesWhenATrackEnds() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        listen.enqueue(try track("First track."))
        listen.enqueue(try track("Second track."))
        #expect(listen.queue.count == 1)
        engine.onFinish?()
        #expect(engine.spoken == ["First track.", "Second track."])
        #expect(listen.queue.isEmpty)
    }

    @Test func skipStaysInsideTheTrack() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        listen.play(try track())
        listen.skip(by: -5)
        listen.skip(by: 9)
        #expect(engine.spoken == ["One.", "One.", "Three."])
    }

    @Test func pauseAndResumeUseTheEngine() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        listen.play(try track())
        listen.togglePause()
        #expect(listen.isPaused)
        listen.togglePause()
        #expect(!listen.isPaused)
        #expect(engine.pauses == 1 && engine.resumes == 1)
        #expect(engine.spoken == ["One."])
    }

    @Test func speedChangeRestartsTheSentence() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        listen.play(try track())
        listen.setSpeed(1.5)
        #expect(engine.spoken == ["One.", "One."])
        #expect(engine.speeds == [1, 1.5])
    }

    @Test("A change while paused waits for play")
    func changeWhilePausedStaysSilent() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        listen.play(try track())
        listen.togglePause()
        listen.setSpeed(1.5)
        #expect(engine.spoken == ["One."])
        listen.togglePause()
        #expect(engine.spoken == ["One.", "One."])
        #expect(engine.speeds.last == 1.5)
        #expect(engine.resumes == 0)
        #expect(!listen.isPaused)
    }

    @Test func stopRemembersWhereItWas() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        var last = -1
        listen.onPosition = { _, offset in last = offset }
        listen.enqueue(try track())
        listen.enqueue(try track())
        listen.skip(by: 1)
        listen.stop()
        #expect(last == 5)
        #expect(listen.current == nil && listen.queue.isEmpty)
    }

    @Test func removingTheCurrentItemMovesOnAndSavesNothing() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        let first = try track("First track.")
        listen.enqueue(first)
        listen.enqueue(try track("Second track."))
        var reported: [UUID] = []
        listen.onPosition = { id, _ in reported.append(id) }
        listen.remove(first.id)
        #expect(listen.current?.title == "Track")
        #expect(engine.spoken.last == "Second track.")
        #expect(!reported.contains(first.id))
    }

    @Test func removingAQueuedItemLeavesPlaybackAlone() throws {
        let engine = FakeSpeechEngine()
        let listen = ListenController(engine: engine)
        let queued = try track("Queued.")
        listen.enqueue(try track("Playing."))
        listen.enqueue(queued)
        listen.remove(queued.id)
        #expect(listen.queue.isEmpty)
        #expect(listen.current != nil)
    }

    @Test func nothingToSayIsNotATrack() {
        #expect(ListenTrack(id: UUID(), title: "Empty", text: "  ") == nil)
    }

    @Test func speedsAreWithinTheSystemRange() {
        for speed in ListenController.speeds + [100] {
            let rate = SystemSpeechEngine.rate(forSpeed: speed)
            #expect(rate > 0 && rate <= 1)
        }
    }

    /// Runs the real synthesizer silently, when TOTALITY_SPEECH_TEST is set. It proves the adapter
    /// delivers word and finish callbacks, which the fake engine cannot.
    @Test func systemEngineFinishesASentence() async throws {
        guard ProcessInfo.processInfo.environment["TOTALITY_SPEECH_TEST"] != nil else { return }
        let engine = SystemSpeechEngine()
        engine.volume = 0
        let listen = ListenController(engine: engine)
        var words: [Int] = []
        let forward = engine.onWord
        engine.onWord = {
            words.append($0)
            forward?($0)
        }
        listen.play(try track("One two three. Four."))
        for _ in 0..<300 where listen.current != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(listen.current == nil)
        #expect(words.contains(4))
    }

    /// Runs the real synthesizer silently too, because stopping and restarting it is what can go wrong.
    @Test("Skip keeps speaking from the new sentence, even from a pause and at both ends")
    func systemEngineSkips() async throws {
        guard ProcessInfo.processInfo.environment["TOTALITY_SPEECH_TEST"] != nil else { return }
        let engine = SystemSpeechEngine()
        engine.volume = 0
        let listen = ListenController(engine: engine)
        var words = 0
        let forward = engine.onWord
        engine.onWord = {
            words += 1
            forward?($0)
        }
        func speechMoved() async throws -> Bool {
            let start = words
            for _ in 0..<100 where words == start {
                try await Task.sleep(for: .milliseconds(50))
            }
            return words > start
        }
        let sentence = "This sentence has plenty of words in it so that it takes a while to say out loud."
        listen.play(try track([sentence, sentence, sentence].joined(separator: " ")))
        #expect(try await speechMoved())

        listen.skip(by: 1)
        #expect(listen.sentence == 1)
        #expect(try await speechMoved())

        listen.skip(by: -1)
        #expect(listen.sentence == 0)
        #expect(try await speechMoved())

        listen.skip(by: -1)
        #expect(listen.sentence == 0)
        #expect(try await speechMoved())

        listen.togglePause()
        listen.skip(by: 1)
        #expect(listen.sentence == 1)
        #expect(!listen.isPaused)
        #expect(try await speechMoved())

        listen.skip(by: 5)
        #expect(listen.sentence == 2)
        #expect(try await speechMoved())

        for _ in 0..<300 where listen.current != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(listen.current == nil)
    }
}

@MainActor
@Suite struct ReaderModelTests {
    private func model(store: MemoryBlobStore = MemoryBlobStore()) throws -> (ReaderModel, FakeSpeechEngine) {
        let engine = FakeSpeechEngine()
        return (ReaderModel(vault: try newVault(store: store), listen: ListenController(engine: engine)), engine)
    }

    @Test("A note deleted while open opens the kept copy, so typing doesn't make another each pause")
    func aKeptCopyOpens() async throws {
        let (model, _) = try model()
        let opened = try #require(await model.newNote())
        await model.delete(opened)
        let result = await model.saveNote(opened.id, title: "Plan", body: "still typing", basedOn: opened.updatedAt)
        guard case .keptAsCopy(let copy) = result else {
            Issue.record("Expected a copy")
            return
        }
        #expect(model.requestedItem == copy.id)
        #expect(model.notice != nil)
    }

    @Test("Old deletions go when the Reader loads, so 30 days holds on a device that's offline")
    func purgeWithoutSync() async throws {
        let store = MemoryBlobStore()
        let (model, _) = try model(store: store)
        let note = try #require(await model.newNote())
        await model.delete(note)
        #expect(model.trash.count == 1)
        let old = Date().addingTimeInterval(-ReaderVault.trashLifetime - 60)
        try store.write(Data(ISO8601DateFormatter().string(from: old).utf8), as: "\(note.id.uuidString.lowercased()).trashed")
        await model.load()
        #expect(model.trash.isEmpty)
    }

    @Test("Deleting a folder takes everything inside out of Listen, and Restore brings it all back")
    func deletingAFolder() async throws {
        let (model, _) = try model()
        await model.newFolder("Climbing", in: nil)
        let folder = try #require(model.library.folders.first)
        let note = try #require(await model.newNote(in: folder.id))
        await model.saveNote(note.id, title: "Beta", body: "Crimp left, flag right.")
        await model.startListening(to: note.id)
        #expect(model.listen.current?.id == note.id)
        await model.delete(folder)
        #expect(model.listen.current == nil)
        #expect(model.items.isEmpty)
        #expect(model.trash.map(\.item.title) == ["Climbing"])
        await model.restore(folder)
        #expect(model.items.map(\.title) == ["Beta"])
        #expect(model.trash.isEmpty)
    }

    @Test func aFailedImportSaysWhichFileAndKeepsTheRest() async throws {
        let (model, _) = try model()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("Good.txt")
        try Data("Fine.".utf8).write(to: good)
        await model.importFiles([directory.appendingPathComponent("Missing.txt"), good])
        #expect(model.items.map(\.title) == ["Good"])
        #expect(model.notice?.contains("Missing.txt") == true)
    }

    @Test func listenResumesAndSavesPosition() async throws {
        let (model, engine) = try model()
        let note = try #require(await model.newNote())
        await model.saveNote(note.id, title: "Note", body: "One. Two.")
        await model.startListening(to: note.id)
        model.listen.skip(by: 1)
        model.listen.stop()
        for _ in 0..<50 {
            await model.load()
            if model.items.first?.listenPosition == 5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.items.first?.listenPosition == 5)
        await model.startListening(to: note.id)
        #expect(engine.spoken.last == "Two.")
    }

    @Test("A rename shows in open search results and the item reads back current")
    func searchResultsFollowARename() async throws {
        let (model, _) = try model()
        let note = try #require(await model.newNote())
        await model.saveNote(note.id, title: "Budget", body: "Numbers")
        model.query = "budget"
        await model.search()
        await model.saveNote(note.id, title: "Budget plan", body: "Numbers")
        #expect(model.hits.map(\.item.title) == ["Budget plan"])
        #expect(try await model.currentItem(note.id).title == "Budget plan")
    }

    @Test func deletingAnItemStopsItPlaying() async throws {
        let (model, engine) = try model()
        let note = try #require(await model.newNote())
        await model.saveNote(note.id, title: "Note", body: "One. Two.")
        await model.startListening(to: note.id)
        await model.delete(note)
        #expect(model.listen.current == nil)
        #expect(engine.spoken == ["One."])
    }

    @Test func addToQueueStartsWhenNothingIsPlaying() async throws {
        let (model, engine) = try model()
        let first = try #require(await model.newNote())
        let second = try #require(await model.newNote())
        await model.saveNote(first.id, title: "A", body: "First.")
        await model.saveNote(second.id, title: "B", body: "Second.")
        await model.addToQueue(first.id)
        await model.addToQueue(second.id)
        #expect(engine.spoken == ["First."])
        #expect(model.listen.queue.map(\.id) == [second.id])
    }

    @Test func listeningToAnEmptyNoteExplains() async throws {
        let (model, engine) = try model()
        let note = try #require(await model.newNote())
        await model.startListening(to: note.id)
        #expect(engine.spoken.isEmpty)
        #expect(model.notice != nil)
    }

    @Test func aDamagedItemIsCountedNotHidden() async throws {
        let store = MemoryBlobStore()
        let (model, _) = try model(store: store)
        let note = try #require(await model.newNote())
        try store.write(Data([1, 2, 3]), as: "\(note.id.uuidString.lowercased()).meta")
        await model.load()
        #expect(model.items.isEmpty)
        #expect(model.unreadable == 1)
    }
}
