import Foundation
import Testing
@testable import TotalityReader

/// Holds each sentence back until the test lets it through, the way a slow model would.
private actor FakeVoice: VoiceSynthesizer {
    private(set) var prepared = 0
    private(set) var requests: [(text: String, speed: Double)] = []
    private let failsPreparing: Bool
    private let unreadable: String?
    private let silent: String?
    private var held: [String: CheckedContinuation<[Float], Never>] = [:]

    init(failsPreparing: Bool = false, unreadable: String? = nil, silent: String? = nil) {
        self.failsPreparing = failsPreparing
        self.unreadable = unreadable
        self.silent = silent
    }

    func prepare() async throws {
        prepared += 1
        if failsPreparing { throw CancellationError() }
    }

    func samples(for text: String, speed: Double) async throws -> [Float] {
        requests.append((text, speed))
        if text == unreadable { throw CancellationError() }
        if text == silent { return [] }
        return await withCheckedContinuation { held[text] = $0 }
    }

    func release(_ text: String) {
        held.removeValue(forKey: text)?.resume(returning: [0.1, 0.2])
    }

    func isHeld(_ text: String) -> Bool {
        held[text] != nil
    }
}

@MainActor
private final class FakeOutput: VoiceOutput {
    var playedFraction = 0.0
    var played: [[Float]] = []
    var pauses = 0
    var resumes = 0
    var stops = 0
    var refuses = false
    var onDone: (@MainActor @Sendable () -> Void)?

    func play(_ samples: [Float], onDone: @escaping @MainActor @Sendable () -> Void) throws {
        if refuses { throw CancellationError() }
        played.append(samples)
        self.onDone = onDone
    }

    func pause() { pauses += 1 }
    func resume() { resumes += 1 }
    func stop() { stops += 1 }
}

@MainActor
private func until(_ condition: () async -> Bool) async throws {
    for _ in 0..<400 where !(await condition()) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await condition())
}

@MainActor
@Suite struct NaturalSpeechTests {
    private let voice = FakeVoice()
    private let output = FakeOutput()

    private func engine(_ voice: FakeVoice? = nil) -> NaturalSpeechEngine {
        NaturalSpeechEngine(synthesizer: voice ?? self.voice, output: output)
    }

    private func speakAndPlay(_ engine: NaturalSpeechEngine, _ text: String) async throws {
        engine.speak(text, speed: 1)
        try await until { await voice.isHeld(text) }
        await voice.release(text)
        let count = output.played.count
        try await until { output.played.count > count }
    }

    @Test func finishesWhenTheAudioHasPlayedNotWhenItWasMade() async throws {
        let engine = engine()
        var finished = 0
        engine.onFinish = { finished += 1 }
        try await speakAndPlay(engine, "One.")
        #expect(finished == 0)
        output.onDone?()
        #expect(finished == 1)
    }

    @Test func theModelLoadsOnce() async throws {
        let engine = engine()
        try await speakAndPlay(engine, "One.")
        try await speakAndPlay(engine, "Two.")
        #expect(await voice.prepared == 1)
    }

    @Test("A sentence that finishes late, after a skip, isn't played")
    func aLateSentenceIsDropped() async throws {
        let engine = engine()
        engine.speak("Old.", speed: 1)
        try await until { await voice.isHeld("Old.") }
        engine.speak("New.", speed: 1)
        try await until { await voice.isHeld("New.") }
        await voice.release("Old.")
        await voice.release("New.")
        try await until { output.played.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(output.played.count == 1)
    }

    @Test("The next sentence is made ahead of time and used, not made twice")
    func aheadIsUsed() async throws {
        let engine = engine()
        try await speakAndPlay(engine, "One.")
        engine.prepare("Two.", speed: 1)
        try await until { await voice.isHeld("Two.") }
        engine.stop()
        engine.speak("Two.", speed: 1)
        await voice.release("Two.")
        try await until { output.played.count == 2 }
        #expect(await voice.requests.map(\.text) == ["One.", "Two."])
    }

    @Test("A speed or sentence change throws away what was made ahead")
    func aheadIsDropped() async throws {
        let engine = engine()
        try await speakAndPlay(engine, "One.")
        engine.prepare("Two.", speed: 1)
        try await until { await voice.isHeld("Two.") }
        engine.speak("Two.", speed: 1.5)
        try await until { await voice.requests.count == 3 }
        await voice.release("Two.")
        let request = try #require(await voice.requests.last)
        #expect(request.speed == 1.5)
    }

    @Test("Skipping while the voice loads doesn't load it again")
    func skippingDuringLoad() async throws {
        let engine = engine()
        engine.speak("One.", speed: 1)
        engine.speak("Two.", speed: 1)
        try await until { await voice.isHeld("Two.") }
        #expect(await voice.prepared == 1)
    }

    @Test("A hint waits for the sentence being made, so the voice isn't loaded twice")
    func aheadWaitsItsTurn() async throws {
        let engine = engine()
        engine.speak("One.", speed: 1)
        engine.prepare("Two.", speed: 1)
        try await until { await voice.isHeld("One.") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await voice.requests.map(\.text) == ["One."])
        await voice.release("One.")
        try await until { await voice.requests.count == 2 }
        #expect(await voice.prepared == 1)
    }

    @Test("With the voice loaded, a hint still waits for the sentence being made")
    func aheadWaitsWhenReady() async throws {
        let engine = engine()
        try await speakAndPlay(engine, "One.")
        engine.speak("Two.", speed: 1)
        engine.prepare("Three.", speed: 1)
        try await until { await voice.isHeld("Two.") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await voice.requests.map(\.text) == ["One.", "Two."])
        await voice.release("Two.")
        try await until { await voice.isHeld("Three.") }
    }

    @Test func aHintBeforeTheVoiceHasLoadedMakesNothing() async throws {
        let engine = engine()
        engine.prepare("Two.", speed: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await voice.requests.isEmpty)
        #expect(await voice.prepared == 0)
    }

    @Test func aRepeatedHintOnlyMakesItOnce() async throws {
        let engine = engine()
        try await speakAndPlay(engine, "One.")
        engine.prepare("Two.", speed: 1)
        engine.prepare("Two.", speed: 1)
        try await until { await voice.isHeld("Two.") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await voice.requests.count == 2)
    }

    @Test func stoppingWhileASentenceIsBeingMadeKeepsItSilent() async throws {
        let engine = engine()
        var finished = 0
        engine.onFinish = { finished += 1 }
        engine.speak("One.", speed: 1)
        try await until { await voice.isHeld("One.") }
        engine.stop()
        await voice.release("One.")
        try await Task.sleep(for: .milliseconds(30))
        #expect(output.played.isEmpty)
        #expect(finished == 0)
    }

    @Test("Playback that ends because of a stop doesn't count as finishing")
    func anOldFinishIsIgnored() async throws {
        let engine = engine()
        var finished = 0
        engine.onFinish = { finished += 1 }
        try await speakAndPlay(engine, "One.")
        let old = output.onDone
        engine.stop()
        old?()
        #expect(finished == 0)
    }

    @Test("Pausing before the audio arrives holds it there")
    func pauseWhileMaking() async throws {
        let engine = engine()
        engine.speak("One.", speed: 1)
        try await until { await voice.isHeld("One.") }
        engine.pause()
        #expect(output.pauses == 0)
        await voice.release("One.")
        try await until { output.pauses == 1 }
        engine.resume()
        #expect(output.resumes == 1)
    }

    @Test func aPauseDoesNotLeakIntoTheNextSentence() async throws {
        let engine = engine()
        try await speakAndPlay(engine, "One.")
        engine.pause()
        #expect(output.pauses == 1)
        try await speakAndPlay(engine, "Two.")
        #expect(output.pauses == 1)
    }

    @Test func saysWhenTheVoiceIsLoadingAndClearsIt() async throws {
        let engine = engine()
        var seen: [String?] = []
        engine.onStatus = { seen.append($0) }
        try await speakAndPlay(engine, "One.")
        #expect(seen.count == 2)
        #expect(seen.first != nil)
        #expect(seen.last == .some(nil))
        try await speakAndPlay(engine, "Two.")
        #expect(seen.count == 2)
    }

    @Test func positionFollowsTheAudio() async throws {
        let engine = engine()
        var offsets: [Int] = []
        engine.onWord = { offsets.append($0) }
        output.playedFraction = 0.5
        engine.reportPosition(textLength: 40)
        output.playedFraction = 1.5
        engine.reportPosition(textLength: 40)
        output.playedFraction = -1
        engine.reportPosition(textLength: 40)
        #expect(offsets == [20, 40, 0])
    }

    @Test("A voice that fails passes its sentence on instead of going quiet")
    func failureHandsBackTheText() async throws {
        let broken = FakeVoice(failsPreparing: true)
        let engine = engine(broken)
        var lost: [String] = []
        var notice: String?
        engine.onFailure = { text, reason in
            lost.append(text)
            notice = reason
        }
        engine.speak("One.", speed: 1)
        try await until { lost == ["One."] }
        #expect(notice != nil)
    }

    @Test func audioThatWontPlayCountsAsAFailure() async throws {
        output.refuses = true
        let engine = engine()
        var lost: [String] = []
        var notices: [String?] = []
        engine.onFailure = { text, notice in
            lost.append(text)
            notices.append(notice)
        }
        engine.speak("One.", speed: 1)
        try await until { await voice.isHeld("One.") }
        await voice.release("One.")
        try await until { lost == ["One."] }
        #expect(notices == [nil])
    }
}

@MainActor
private final class Finished {
    var value = false
}

@MainActor
@Suite struct RealVoiceOutputTests {
    @Test func emptyAudioIsRefused() {
        #expect(throws: (any Error).self) { try EngineVoiceOutput().play([]) {} }
    }

    /// Runs the real audio engine when TOTALITY_SPEECH_TEST is set. Its finish callback arrives on
    /// the audio queue, which only the real engine can show.
    @Test func realPlaybackFinishesOffTheMainThreadWithoutTrapping() async throws {
        guard ProcessInfo.processInfo.environment["TOTALITY_SPEECH_TEST"] != nil else { return }
        let output = EngineVoiceOutput()
        let finished = Finished()
        try output.play([Float](repeating: 0, count: 4_800)) { finished.value = true }
        try await until { finished.value }
    }
}

@MainActor
@Suite struct ListenVoicesTests {
    private let voice = FakeVoice()
    private let output = FakeOutput()
    private let system = FakeSpeechEngine()

    private func voices(_ voice: FakeVoice? = nil) -> ListenVoices {
        ListenVoices(
            system: system,
            natural: NaturalSpeechEngine(synthesizer: voice ?? self.voice, output: output)
        )
    }

    @Test("Listening starts in the natural voice without being asked")
    func theNaturalVoiceIsTheDefault() async throws {
        let listen = ListenController(engine: voices())
        listen.setSpeed(1.5)
        listen.play(try #require(ListenTrack(id: UUID(), title: "Track", text: "One. Two.")))
        try await until { await voice.isHeld("One.") }
        #expect(system.spoken.isEmpty)
        let request = try #require(await voice.requests.first)
        #expect(request.speed == 1.5)
    }

    @Test func theNextSentenceIsHintedAndTheHintEndsWithTheTrack() throws {
        let listen = ListenController(engine: system)
        listen.play(try #require(ListenTrack(id: UUID(), title: "Track", text: "One. Two.")))
        #expect(system.prepared == ["Two."])
        system.onFinish?()
        #expect(system.prepared == ["Two.", nil])
        listen.stop()
        #expect(system.prepared == ["Two.", nil, nil])
    }

    @Test("Removing an item drops what was made ahead of it")
    func removalDropsTheHint() throws {
        let listen = ListenController(engine: system)
        let track = try #require(ListenTrack(id: UUID(), title: "Track", text: "One. Two."))
        listen.play(track)
        listen.remove(track.id)
        #expect(system.prepared.last == .some(nil))
    }

    @Test("With no natural voice on this OS, the system voice reads")
    func withoutTheNaturalVoice() {
        let voices = ListenVoices(system: system, natural: nil)
        voices.speak("One.", speed: 1)
        voices.pause()
        voices.resume()
        #expect(system.spoken == ["One."])
        #expect(system.pauses == 1)
        #expect(system.resumes == 1)
    }

    @Test("Pause reaches only the engine that's speaking")
    func pauseGoesToTheSpeakingEngine() async throws {
        let voices = voices()
        voices.speak("One.", speed: 1)
        try await until { await voice.isHeld("One.") }
        voices.pause()
        #expect(system.pauses == 0)
    }

    @Test("If the voice can't load, listening carries on in the system voice, and it says so")
    func fallsBackOnce() async throws {
        let broken = FakeVoice(failsPreparing: true)
        let voices = voices(broken)
        let listen = ListenController(engine: voices)
        let track = try #require(ListenTrack(id: UUID(), title: "Track", text: "One. Two."))
        listen.play(track)
        try await until { system.spoken == ["One."] }
        #expect(system.speeds == [1])
        #expect(listen.status != nil)
        system.onFinish?()
        try await until { system.spoken == ["One.", "Two."] }
        #expect(await broken.prepared == 1)
        #expect(listen.status != nil)
    }

    @Test("Text with nothing to say is skipped, with no voice change")
    func nothingToSay() async throws {
        let voices = voices(FakeVoice(silent: "🙂"))
        var finished = 0
        voices.onFinish = { finished += 1 }
        voices.speak("🙂", speed: 1)
        try await until { finished == 1 }
        #expect(system.spoken.isEmpty)
        #expect(output.played.isEmpty)
    }

    @Test("Text the voice can't read goes to the system voice, and the voice carries on")
    func oneBadSentence() async throws {
        let voices = voices(FakeVoice(unreadable: "•"))
        var statuses: [String?] = []
        voices.onStatus = { statuses.append($0) }
        voices.speak("•", speed: 1)
        try await until { system.spoken == ["•"] }
        #expect(statuses.last == .some(nil))
        voices.speak("Two.", speed: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(system.spoken == ["•"])
        voices.pause()
        #expect(system.pauses == 0)
    }

    @Test("Text that can't be made ahead still reaches the system voice in its turn")
    func oneBadSentenceMadeAhead() async throws {
        let bad = FakeVoice(unreadable: "•")
        let voices = voices(bad)
        voices.speak("One.", speed: 1)
        try await until { await bad.isHeld("One.") }
        await bad.release("One.")
        try await until { output.played.count == 1 }
        voices.prepare("•", speed: 1)
        try await until { await bad.requests.count == 2 }
        voices.speak("•", speed: 1)
        try await until { system.spoken == ["•"] }
    }

    @Test func aVoiceThatWontLoadIsNotAskedForAnythingElse() async throws {
        let broken = FakeVoice(failsPreparing: true)
        let voices = voices(broken)
        voices.speak("One.", speed: 1)
        try await until { system.spoken == ["One."] }
        voices.prepare("Two.", speed: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await broken.requests.isEmpty)
        #expect(await broken.prepared == 1)
    }

    @Test func theSameSpeedCarriesOverWhenItFallsBack() async throws {
        let broken = FakeVoice(failsPreparing: true)
        let voices = voices(broken)
        voices.speak("One.", speed: 1.5)
        try await until { system.spoken == ["One."] }
        #expect(system.speeds == [1.5])
    }
}

@Suite struct VoicePackTests {
    private let models = "kokoro-82m-coreml/ANE-v3/6c0750dd02ef9d981fb82f147d784a3f171755ee/en"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pack() throws -> URL {
        let pack = try folder()
        let files = FileManager.default
        try files.createDirectory(at: pack.appendingPathComponent("kokoro"), withIntermediateDirectories: true)
        try files.createDirectory(at: pack.appendingPathComponent("\(models)/base/Model.mlmodelc"), withIntermediateDirectories: true)
        for name in ["manifest.json", "base-index-v3.json", "vocab.json"] {
            try Data(name.utf8).write(to: pack.appendingPathComponent("\(models)/\(name)"))
        }
        return pack
    }

    @Test func theVoiceIsLinkedNotCopied() throws {
        guard #available(iOS 18, macOS 15, *) else { return }
        let pack = try pack()
        let directory = try folder()
        try KokoroSynthesizer.link(pack, into: directory)
        let files = FileManager.default
        for name in ["\(models)/base/Model.mlmodelc", "\(models)/vocab.json"] {
            let link = try files.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(name).path)
            #expect(link == pack.appendingPathComponent(name).path)
        }
    }

    @Test("FluidAudio lists its folders, and it can't list a link")
    func foldersAreRealFolders() throws {
        guard #available(iOS 18, macOS 15, *) else { return }
        let pack = try pack()
        let directory = try folder()
        try KokoroSynthesizer.link(pack, into: directory)
        let base = directory.appendingPathComponent("\(models)/base")
        #expect(try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).count == 1)
        #expect(throws: (any Error).self) { try FileManager.default.destinationOfSymbolicLink(atPath: base.path) }
    }

    @Test("FluidAudio can rewrite its two files without touching the read-only app")
    func theRewrittenFilesAreCopies() throws {
        guard #available(iOS 18, macOS 15, *) else { return }
        let pack = try pack()
        let directory = try folder()
        try KokoroSynthesizer.link(pack, into: directory)
        for name in ["manifest.json", "base-index-v3.json"] {
            let copy = directory.appendingPathComponent("\(models)/\(name)")
            #expect(throws: (any Error).self) { try FileManager.default.destinationOfSymbolicLink(atPath: copy.path) }
            try Data("new".utf8).write(to: copy)
            #expect(try Data(contentsOf: pack.appendingPathComponent("\(models)/\(name)")) == Data(name.utf8))
        }
    }

    @Test("An update moves the app, so the links follow, and the old download goes")
    func linkingAgainStartsClean() throws {
        guard #available(iOS 18, macOS 15, *) else { return }
        let directory = try folder()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("kokoro"), withIntermediateDirectories: true)
        let oldDownload = directory.appendingPathComponent("kokoro/weight.bin")
        try Data("old".utf8).write(to: oldDownload)
        let first = try pack()
        try KokoroSynthesizer.link(first, into: directory)
        #expect(!FileManager.default.fileExists(atPath: oldDownload.path))
        let moved = try pack()
        try KokoroSynthesizer.link(moved, into: directory)
        let vocab = "\(models)/vocab.json"
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(vocab).path)
        #expect(link == moved.appendingPathComponent(vocab).path)
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("\(models)/vocab.json").path))
    }

    /// Set TOTALITY_VOICE_PACK to an unpacked Voice folder. The network address is dead, so passing also
    /// shows nothing was fetched.
    @Test func theRealPackSpeaksWithoutTheNetwork() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOTALITY_VOICE_PACK"],
              #available(iOS 18, macOS 15, *) else { return }
        let voice = KokoroSynthesizer(pack: URL(fileURLWithPath: path), directory: try folder())
        try await voice.prepare()
        #expect(try await voice.samples(for: "It works.", speed: 1).count > 1_000)
    }
}

@Suite struct PDFTextTests {
    private func sentences(_ text: String) -> [String] {
        ListenScript(text: text).sentences.map(\.text)
    }

    @Test("A line break that only ran out of page doesn't end the sentence")
    func wrappedLinesJoin() {
        let text = "The port of Lisbon grew quickly after the ships of Gama came\nhome from India. It kept growing."
        #expect(sentences(text) == ["The port of Lisbon grew quickly after the ships of Gama came home from India.", "It kept growing."])
    }

    @Test func aWordSplitAcrossLinesIsMended() {
        let text = "The port of Lis-\nbon grew quickly after the fleet came home."
        #expect(sentences(text) == ["The port of Lisbon grew quickly after the fleet came home."])
    }

    @Test func aRealHyphenStays() {
        let text = "It was a well-known route.\nA self-\nMade trader."
        #expect(sentences(text).first == "It was a well-known route.")
        #expect(sentences(text).joined().contains("self-"))
    }

    @Test("Offsets still point at the original text")
    func offsetsSurvive() {
        let text = "The port of Lis-\nbon grew quickly after the fleet came home.\n\nNext one."
        let script = ListenScript(text: text)
        #expect(script.length == text.utf16.count)
        let last = try! #require(script.sentences.last)
        #expect(last.text == "Next one.")
        let start = String.Index(utf16Offset: last.offset, in: text)
        #expect(text[start...].trimmingCharacters(in: .whitespacesAndNewlines) == "Next one.")
    }

    @Test func aBlankLineEndsAParagraph() {
        #expect(sentences("A heading\n\nThe body starts here.") == ["A heading", "The body starts here."])
    }

    @Test func headingsAndListsKeepTheirLines() {
        #expect(sentences("CHAPTER IV\nTHE RIVER TRADE") == ["CHAPTER IV", "THE RIVER TRADE"])
        let list = "These were the goods that the ships brought back to the city:\n• Pepper by the ton\n• Cloves"
        #expect(sentences(list).count == 3)
    }

    @Test("Bullets, rules, page numbers, and table figures aren't read")
    func nothingToRead() {
        #expect(sentences("Words here.\n\n* * *\n\n43\n\n•\n\n1500   12   4,800\n\nMore words.") == ["Words here.", "More words."])
    }

    @Test("Abbreviations don't end a sentence", arguments: [
        "St. Vincent's Day falls in January.",
        "Fig. 3 shows the tonnage.",
        "See vol. 2 of the set.",
        "J. Silva wrote it in Lisbon.",
        "1. Merchants read the ledgers daily.",
    ])
    func abbreviationsCarryOn(text: String) {
        #expect(sentences(text) == [text])
    }

    @Test func aRealSentenceEndStillSplits() {
        #expect(sentences("He said no. They left.").count == 2)
    }
}

@Suite struct SpokenTextTests {
    @Test("Each is rewritten for reading aloud", arguments: [
        ("See Fig. 3 for the tonnage.", "See Figure 3 for the tonnage."),
        ("It's on pp. 12 to 14, or p. 9.", "It's on pages 12 to 14, or page 9."),
        ("Trade grew fast [12], then fell [3, 4].", "Trade grew fast, then fell."),
        ("Cloves cost 2× as much.", "Cloves cost 2 times as much."),
        ("• Pepper arrived.", "Pepper arrived."),
        ("See https://www.example.org/lisbon?id=4 for more.", "See example.org for more."),
    ])
    func rewrites(text: String, spoken: String) {
        #expect(SpokenText.prepared(text) == spoken)
    }

    @Test("Words that change sound with their use", arguments: [
        ("They had read them yesterday.", "They had red them yesterday."),
        ("They live near the docks.", "They liv near the docks."),
        ("Merchants read the ledgers daily.", "Merchants read the ledgers daily."),
        ("It was a live broadcast.", "It was a live broadcast."),
        ("She gave him a present.", "She gave him a present."),
        ("They will present the record.", "They will prezent the record."),
    ])
    func respells(text: String, spoken: String) {
        #expect(SpokenText.prepared(text) == spoken)
    }

    @Test("Silence around a sentence goes, and a short rest stays")
    func trimsSilence() {
        let rate = 24_000
        let speech = [Float](repeating: 0.5, count: rate)
        let padded = [Float](repeating: 0, count: rate / 2) + speech + [Float](repeating: 0, count: rate)
        let trimmed = SpokenAudio.trimmed(padded)
        #expect(trimmed.count == rate + Int(0.03 * 24_000) + Int(0.18 * 24_000))
        #expect(trimmed.first == 0)
        #expect(trimmed[Int(0.03 * 24_000)] == 0.5)
    }

    @Test func silenceAloneIsLeftAlone() {
        let quiet = [Float](repeating: 0, count: 100)
        #expect(SpokenAudio.trimmed(quiet) == quiet)
    }
}
