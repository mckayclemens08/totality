import Foundation
import Testing
@testable import TotalityReader

/// Holds each sentence back until the test lets it through, the way a slow model would.
private actor FakeVoice: VoiceSynthesizer {
    nonisolated let needsDownload: Bool
    private(set) var prepared = 0
    private(set) var requests: [(text: String, speed: Double)] = []
    private let loadError: (any Error)?
    private let unreadable: String?
    private var held: [String: CheckedContinuation<[Float], Never>] = [:]

    init(failsPreparing: Bool = false, loadError: (any Error)? = nil, unreadable: String? = nil, needsDownload: Bool = false) {
        self.loadError = failsPreparing ? CancellationError() : loadError
        self.unreadable = unreadable
        self.needsDownload = needsDownload
    }

    func prepare() async throws {
        prepared += 1
        if let loadError { throw loadError }
    }

    func samples(for text: String, speed: Double) async throws -> [Float] {
        requests.append((text, speed))
        if text == unreadable { throw CancellationError() }
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

    @Test("The first run says how big the download is")
    func downloadStatus() async throws {
        let engine = engine(FakeVoice(needsDownload: true))
        var seen: [String?] = []
        engine.onStatus = { seen.append($0) }
        engine.speak("One.", speed: 1)
        let first = try #require(seen.compactMap { $0 }.first)
        #expect(first.contains("390 MB"))
    }

    @Test func aLoadedVoiceSaysNothingAboutDownloading() async throws {
        let engine = engine()
        var seen: [String?] = []
        engine.onStatus = { seen.append($0) }
        engine.speak("One.", speed: 1)
        let first = try #require(seen.compactMap { $0 }.first)
        #expect(!first.contains("390 MB"))
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

    @Test("On cellular the download waits, the system voice reads, and it says why")
    func waitsForWiFi() async throws {
        let waiting = FakeVoice(loadError: VoiceLoadError.waitingForWiFi, needsDownload: true)
        let voices = voices(waiting)
        var statuses: [String?] = []
        voices.onStatus = { statuses.append($0) }
        voices.speak("One.", speed: 1)
        try await until { system.spoken == ["One."] }
        let status = try #require(statuses.compactMap { $0 }.last)
        #expect(status.contains("Wi-Fi"))
        voices.speak("Two.", speed: 1)
        #expect(system.spoken == ["One.", "Two."])
        #expect(await waiting.prepared == 1)
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

@Suite struct VoiceDownloadTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theDownloadNeverStartsOnAMeteredNetwork() async throws {
        guard #available(iOS 18, macOS 15, *) else { return }
        let voice = KokoroSynthesizer(directory: try directory(), isMetered: { true })
        #expect(voice.needsDownload)
        await #expect(throws: VoiceLoadError.self) { try await voice.prepare() }
        #expect(voice.needsDownload)
    }

    @Test func aDownloadedVoiceDoesNotAskAgain() throws {
        guard #available(iOS 18, macOS 15, *) else { return }
        let folder = try directory()
        FileManager.default.createFile(atPath: folder.appendingPathComponent(KokoroSynthesizer.downloadedMarker).path, contents: nil)
        #expect(!KokoroSynthesizer(directory: folder, isMetered: { true }).needsDownload)
    }

    @Test func theNetworkCheckAnswers() async {
        guard #available(iOS 18, macOS 15, *) else { return }
        _ = await KokoroSynthesizer.onMeteredNetwork()
    }
}

@Suite struct VoiceAssetsTests {
    private let good = Data("good".utf8)
    private let goodHash = "770e607624d689265ca6c44884d0807d9b054d23c473c106c72be9de08b7376c"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ directory: URL) -> URL {
        directory.appendingPathComponent("kokoro/folder/file.bin")
    }

    @Test func theRightFileIsSaved() async throws {
        let folder = try directory()
        let good = good
        try await VoiceAssets.install(in: folder, files: [("folder/file.bin", goodHash)]) { _ in good }
        #expect(try Data(contentsOf: file(folder)) == good)
    }

    @Test("A file that doesn't match its hash is refused and never reaches the disk")
    func aWrongFileIsRefused() async throws {
        let folder = try directory()
        await #expect(throws: VoiceLoadError.self) {
            try await VoiceAssets.install(in: folder, files: [("folder/file.bin", goodHash)]) { _ in Data("bad".utf8) }
        }
        #expect(!FileManager.default.fileExists(atPath: file(folder).path))
    }

    @Test func files_comeFromOneCommit() async throws {
        let folder = try directory()
        let good = good
        try await VoiceAssets.install(in: folder, files: [("folder/file.bin", goodHash)]) { url in
            #expect(url.absoluteString.contains("/resolve/2568276a60ff6e7f312afce3dc9e3f07521cb48d/folder/file.bin"))
            #expect(url.host() == "huggingface.co")
            return good
        }
    }

    @Test func aGoodFileIsntFetchedAgain() async throws {
        let folder = try directory()
        let good = good
        try await VoiceAssets.install(in: folder, files: [("folder/file.bin", goodHash)]) { _ in good }
        try await VoiceAssets.install(in: folder, files: [("folder/file.bin", goodHash)]) { _ in
            Issue.record("fetched a file it already had")
            return Data()
        }
    }

    @Test func aChangedFileIsReplaced() async throws {
        let folder = try directory()
        try FileManager.default.createDirectory(at: file(folder).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("changed".utf8).write(to: file(folder))
        let good = good
        try await VoiceAssets.install(in: folder, files: [("folder/file.bin", goodHash)]) { _ in good }
        #expect(try Data(contentsOf: file(folder)) == good)
    }

    @Test("Everything FluidAudio would otherwise fetch unchecked is on the list")
    func theListIsComplete() {
        let paths = Set(VoiceAssets.files.map(\.path))
        for bundle in ["G2PEncoder.mlmodelc", "G2PDecoder.mlmodelc"] {
            for name in ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"] {
                #expect(paths.contains("\(bundle)/\(name)"))
            }
        }
        #expect(paths.contains("g2p_vocab.json"))
        #expect(paths.contains("us_lexicon_cache.json"))
        #expect(VoiceAssets.files.allSatisfy { $0.sha256.count == 64 })
    }

    @Test func theBaseListingIsWrittenWhereFluidAudioReadsIt() async throws {
        let folder = try directory()
        try await VoiceAssets.install(in: folder, files: []) { _ in Data() }
        let written = VoiceAssets.voiceFile(in: folder).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("base-index-v3.json")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [[String: Any]]
        #expect(rows?.isEmpty == false)
        #expect(rows?.allSatisfy { $0["path"] is String && $0["oid"] is String } == true)
    }

    @Test("A voice pack that doesn't match is thrown away")
    func aWrongVoiceIsRefused() throws {
        let folder = try directory()
        let voice = VoiceAssets.voiceFile(in: folder)
        try FileManager.default.createDirectory(at: voice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: voice)
        #expect(throws: VoiceLoadError.self) { try VoiceAssets.checkVoice(in: folder) }
        #expect(!FileManager.default.fileExists(atPath: voice.path))
    }

    /// Downloads the whole voice into a new folder, so it only runs when TOTALITY_VOICE_DOWNLOAD is set.
    @Test func theRealVoiceInstallsAndSpeaks() async throws {
        guard ProcessInfo.processInfo.environment["TOTALITY_VOICE_DOWNLOAD"] != nil,
              #available(iOS 18, macOS 15, *) else { return }
        let folder = try directory()
        let lexicon = folder.appendingPathComponent("kokoro/us_lexicon_cache.json")
        try await VoiceAssets.install(in: folder)
        let installed = try lexicon.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let voice = KokoroSynthesizer(directory: folder, isMetered: { false })
        try await voice.prepare()
        #expect(!voice.needsDownload)
        #expect(try lexicon.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == installed)
        #expect(try await voice.samples(for: "It works.", speed: 1).count > 1_000)
    }
}

