import Foundation
import Testing
@testable import TotalityReader

/// Holds each sentence back until the test lets it through, the way a slow model would.
private actor FakeVoice: VoiceSynthesizer {
    private(set) var prepared = 0
    private(set) var requests: [(text: String, speed: Double)] = []
    var failsPreparing = false
    private var held: [String: CheckedContinuation<[Float], Never>] = [:]

    init(failsPreparing: Bool = false) {
        self.failsPreparing = failsPreparing
    }

    func prepare() async throws {
        prepared += 1
        if failsPreparing { throw CancellationError() }
    }

    func samples(for text: String, speed: Double) async -> [Float] {
        requests.append((text, speed))
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
        engine.onFailure = { lost.append($0) }
        engine.speak("One.", speed: 1)
        try await until { lost == ["One."] }
    }

    @Test func audioThatWontPlayCountsAsAFailure() async throws {
        output.refuses = true
        let engine = engine()
        var lost: [String] = []
        engine.onFailure = { lost.append($0) }
        engine.speak("One.", speed: 1)
        try await until { await voice.isHeld("One.") }
        await voice.release("One.")
        try await until { lost == ["One."] }
    }
}

@MainActor
private final class Finished {
    var value = false
}

@MainActor
@Suite struct RealVoiceOutputTests {
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

    @Test func theSameSpeedCarriesOverWhenItFallsBack() async throws {
        let broken = FakeVoice(failsPreparing: true)
        let voices = voices(broken)
        voices.speak("One.", speed: 1.5)
        try await until { system.spoken == ["One."] }
        #expect(system.speeds == [1.5])
    }
}
