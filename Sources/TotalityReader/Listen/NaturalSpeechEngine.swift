import AVFoundation
import FluidAudio

/// Turns text into audio samples. Nothing here leaves the device: only the model is ever downloaded.
protocol VoiceSynthesizer: Sendable {
    /// Loads the voice, so it can speak.
    func prepare() async throws
    func speech(for text: String) async throws -> VoiceSpeech
    /// Lines to say, unheard, once the voice has loaded and nothing is waiting to be read.
    var warmUpLines: [String] { get }
    /// Says one warm-up line and throws the sound away. Only a full disk is worth an error.
    func warmUp(with line: String) async throws
}

extension VoiceSynthesizer {
    var warmUpLines: [String] { [] }
    func warmUp(with line: String) async throws {}
}

/// Why the voice couldn't load, when that's something the listener can fix.
enum VoiceLoadError: Error {
    case storageFull
}

/// Plays one run of samples at a time.
@MainActor
protocol VoiceOutput: AnyObject {
    /// How far through the current samples playback has got, from 0 to 1.
    var playedFraction: Double { get }
    func play(_ samples: [Float], rate: Double, onDone: @escaping @MainActor @Sendable () -> Void) throws
    func pause()
    func resume()
    func stop()
}

/// Reads with a neural voice that runs on this device. Making a sentence takes about a second on a
/// phone, so the next one is made ahead of time. Otherwise every sentence would end in a long pause.
@MainActor
final class NaturalSpeechEngine: SpeechEngine {
    /// Short enough for a word highlight to keep up at twice the speed.
    private static let positionPause = Duration.milliseconds(50)
    /// One failed sentence is about that sentence. Two in a row is about the voice.
    private static let failuresBeforeNotice = 2

    var onFinish: (() -> Void)?
    var onWord: ((Int) -> Void)?
    var onStatus: ((String?) -> Void)?
    /// Called with text that couldn't be spoken. The notice is there when the voice itself didn't load,
    /// and it's nil when only this text failed, as a lone bullet does.
    var onFailure: ((_ text: String, _ notice: String?) -> Void)?

    private let synthesizer: any VoiceSynthesizer
    private let output: any VoiceOutput
    private var isReady = false
    /// Shared and never cancelled, because skipping during a load shouldn't start it again.
    private var loading: Task<Void, any Error>?
    /// Warm-up lines not yet said. Speech that's asked for goes first, so a line only runs when nothing waits.
    private var warmUpsLeft: [String]?
    private var warming: Task<Void, Never>?
    /// A sentence was promised, so no warm-up line starts in front of it.
    private var isExpecting = false

    private var isPaused = false
    private var isPlaying = false
    private var isWaiting = false
    /// Moves on with every speak and stop, so work that finishes late can see it's out of date.
    private var turn = 0
    private var making: Task<Void, Never>?
    private var ahead: (text: String, speech: Task<VoiceSpeech, any Error>)?
    private var wanted: String?
    private var position: Task<Void, Never>?
    /// What's playing, and the last place reported, so a place is only reported when it changes.
    private var playing: (length: Int, marks: [VoiceMark], shift: Int) = (0, [], 0)
    /// The second half of a sentence that was made in two, being made while the first half plays.
    private var rest: Rest?

    private struct Rest {
        let text: String
        /// Where it starts in the whole sentence, in UTF-16 units.
        let shift: Int
        let speed: Double
        let speech: Task<VoiceSpeech, any Error>
    }

    /// A sentence nobody made ahead is said in two when it's long, split after its first clause, so
    /// speech starts when that clause is made rather than the whole sentence. Kokoro pauses there anyway,
    /// and splits long text at the same marks itself.
    static let splitsAbove = 80
    static let shortestPart = 20
    static let longestOpening = 120
    private var lastOffset: Int?
    private var failuresInARow = 0

    init(synthesizer: any VoiceSynthesizer, output: any VoiceOutput) {
        self.synthesizer = synthesizer
        self.output = output
    }

    /// Starts loading the voice before anything is asked for, so the first sentence doesn't wait for it.
    func warmUp(speakingSoon: Bool) {
        if speakingSoon { isExpecting = true }
        _ = load()
    }

    private func load() -> Task<Void, any Error>? {
        guard !isReady else { return nil }
        if let loading { return loading }
        let synthesizer = self.synthesizer
        let task = Task { try await synthesizer.prepare() }
        loading = task
        if warmUpsLeft == nil { warmUpsLeft = synthesizer.warmUpLines }
        Task { [weak self] in
            guard (try? await task.value) != nil else { return }
            self?.isReady = true
            self?.warmNext()
        }
        return task
    }

    /// Core ML finishes each model the first time it runs. These lines do that while the voice is idle,
    /// which keeps the wait out of the middle of a chapter without making the first sentence wait for it.
    private func warmNext() {
        guard isReady, !isExpecting, warming == nil, making == nil, ahead == nil, !isPlaying,
              let line = warmUpsLeft?.first else { return }
        warmUpsLeft?.removeFirst()
        let synthesizer = self.synthesizer
        warming = Task { [weak self] in
            do {
                try await synthesizer.warmUp(with: line)
            } catch {
                self?.cannotLoad()
            }
            self?.warming = nil
            self?.warmNext()
        }
    }

    /// The disk filled up while warming, so the next sentence says why the voice can't run.
    private func cannotLoad() {
        isReady = false
        warmUpsLeft = []
        loading = Task { throw VoiceLoadError.storageFull }
    }

    func speak(_ text: String, speed: Double) {
        stop()
        isExpecting = false
        let current = turn
        let held = ahead?.text == text ? ahead?.speech : nil
        if held == nil { ahead?.speech.cancel() }
        ahead = nil
        wanted = nil
        let synthesizer = self.synthesizer
        let split = held == nil ? Self.firstClause(of: text) : nil
        let load = load()
        if load != nil {
            isWaiting = true
            onStatus?("Getting the voice ready.")
        }
        making = Task { [weak self] in
            do {
                try await load?.value
            } catch VoiceLoadError.storageFull {
                self?.failed(text, notice: "Storage is almost full, so Michael can't run. Free up space, then reopen the app.", turn: current)
                return
            } catch {
                self?.failed(text, notice: "Michael's voice didn't load, so this is the system voice.", turn: current)
                return
            }
            self?.isReady = true
            do {
                if let split {
                    let opening = try await synthesizer.speech(for: split.opening)
                    // Only now, so the rest can't hold up the opening.
                    let rest = Rest(
                        text: split.rest, shift: split.shift, speed: speed,
                        speech: Task { try await synthesizer.speech(for: split.rest) }
                    )
                    self?.made(opening, text: split.opening, speed: speed, turn: current, rest: rest)
                    return
                }
                let speech = if let held {
                    try await held.value
                } else {
                    try await synthesizer.speech(for: text)
                }
                self?.made(speech, text: text, speed: speed, turn: current)
            } catch {
                self?.failed(text, notice: nil, turn: current)
            }
        }
    }

    func prepare(_ text: String?) {
        guard let text else {
            ahead?.speech.cancel()
            ahead = nil
            wanted = nil
            return
        }
        guard ahead?.text != text else { return }
        ahead?.speech.cancel()
        ahead = nil
        wanted = text
        makeAhead()
    }

    /// Waits for the sentence being made, so the voice is only ever loaded once.
    private func makeAhead() {
        guard isReady, making == nil, let wanted else {
            warmNext()
            return
        }
        self.wanted = nil
        let synthesizer = self.synthesizer
        ahead = (wanted, Task {
            try await synthesizer.speech(for: wanted)
        })
    }

    func pause() {
        isPaused = true
        if isPlaying { output.pause() }
    }

    func resume() {
        isPaused = false
        if isPlaying { output.resume() }
    }

    func stop() {
        turn += 1
        making?.cancel()
        making = nil
        rest?.speech.cancel()
        rest = nil
        position?.cancel()
        position = nil
        isPlaying = false
        isPaused = false
        doneWaiting()
        output.stop()
    }

    /// One sentence's position: the word that's started, or without marks an estimate from the audio
    /// played. Offsets are UTF-16, the same as speech's.
    static func offset(forFraction fraction: Double, inTextOfLength length: Int, marks: [VoiceMark] = []) -> Int {
        let played = min(max(fraction, 0), 1)
        guard !marks.isEmpty else { return Int(played * Double(length)) }
        return marks.last { $0.fraction <= played }?.offset ?? marks[0].offset
    }

    func reportPosition() {
        let offset = playing.shift + Self.offset(forFraction: output.playedFraction, inTextOfLength: playing.length, marks: playing.marks)
        guard offset != lastOffset else { return }
        lastOffset = offset
        onWord?(offset)
    }

    /// Where a long sentence that isn't ready can be split, or nil to say it whole.
    static func firstClause(of text: String) -> (opening: String, rest: String, shift: Int)? {
        guard text.count > splitsAbove else { return nil }
        var count = 0
        for index in text.indices {
            count += 1
            guard count <= longestOpening else { return nil }
            guard count >= shortestPart, ",;:".contains(text[index]) else { continue }
            let after = text.index(after: index)
            guard after < text.endIndex, text[after].isWhitespace else { continue }
            guard let start = text[after...].firstIndex(where: { !$0.isWhitespace }) else { return nil }
            let rest = String(text[start...])
            guard rest.count >= shortestPart else { return nil }
            return (String(text[...index]), rest, start.utf16Offset(in: text))
        }
        return nil
    }

    private func made(_ speech: VoiceSpeech, text: String, speed: Double, turn: Int, shift: Int = 0, rest: Rest? = nil) {
        guard turn == self.turn else {
            rest?.speech.cancel()
            return
        }
        making = nil
        self.rest = rest
        doneWaiting()
        if failuresInARow >= Self.failuresBeforeNotice { onStatus?(nil) }
        failuresInARow = 0
        guard !speech.samples.isEmpty else {
            played(turn: turn)
            return
        }
        do {
            try output.play(speech.samples, rate: speed) { [weak self] in self?.played(turn: turn) }
        } catch {
            failed(text, notice: nil, turn: turn)
            return
        }
        isPlaying = true
        if isPaused { output.pause() }
        playing = (text.utf16.count, speech.marks, shift)
        lastOffset = nil
        position = Task { [weak self] in
            while !Task.isCancelled {
                self?.reportPosition()
                try? await Task.sleep(for: Self.positionPause)
            }
        }
        // The rest of this sentence comes first, so the next one waits until that's made.
        if rest == nil { makeAhead() }
    }

    private func played(turn: Int) {
        guard turn == self.turn else { return }
        position?.cancel()
        position = nil
        isPlaying = false
        if let rest {
            self.rest = nil
            making = Task { [weak self] in
                do {
                    let speech = try await rest.speech.value
                    self?.made(speech, text: rest.text, speed: rest.speed, turn: turn, shift: rest.shift)
                } catch {
                    self?.failed(rest.text, notice: nil, turn: turn)
                }
            }
            return
        }
        onFinish?()
    }

    private func failed(_ text: String, notice: String?, turn: Int) {
        guard turn == self.turn, !Task.isCancelled else { return }
        making = nil
        isPlaying = false
        doneWaiting()
        failuresInARow += 1
        if failuresInARow == Self.failuresBeforeNotice, notice == nil {
            onStatus?("Michael isn't working right now, so this is the system voice.")
        }
        onFailure?(text, notice)
    }

    private func doneWaiting() {
        guard isWaiting else { return }
        isWaiting = false
        onStatus?(nil)
    }
}

/// Kokoro, through a pinned FluidAudio release. The voice ships in the app, signed with it.
@available(iOS 18, macOS 15, *)
final class KokoroSynthesizer: VoiceSynthesizer {
    private static let voice = "am_michael"
    /// FluidAudio rewrites these two every time, so they can't be links into the read-only app.
    private static let rewritten: Set<String> = ["manifest.json", "base-index-v3.json"]
    /// Below this, a load that fails is put down to storage. Core ML writes each model's compiled form to disk.
    private static let storageNeeded: Int64 = 1_000_000_000
    /// Between them these run every model: the two short routes and the one for longer sentences.
    private static let warmUp = [
        "Hello there.",
        "This short line is here to warm the voice up.",
        "This longer line is here to warm the voice up, so the first long sentence doesn't have to wait for it.",
    ]

    private let manager: KokoroAneManager
    private let pack: URL
    private let directory: URL

    init(pack: URL, directory: URL) {
        // A word the model can't read is logged, so the log mustn't reach stderr. The system log keeps it private.
        AppLogger.mirrorsToConsole = false
        // Everything is in the app, so a missing file should fail here, not go looking on the network.
        ModelRegistry.baseURL = "https://voice.invalid"
        self.pack = pack
        self.directory = directory
        manager = KokoroAneManager(directory: directory, version: .v3)
    }

    func prepare() async throws {
        do {
            try Self.link(pack, into: directory)
            try await manager.initialize(preloadVoices: [Self.voice])
        } catch {
            throw isOutOfRoom ? VoiceLoadError.storageFull : error
        }
    }

    var warmUpLines: [String] {
        Self.warmUp
    }

    /// A locked screen can refuse this for now, so only a full disk counts as failing.
    func warmUp(with line: String) async throws {
        do {
            _ = try await manager.synthesizeDetailed(text: line, voice: Self.voice, speed: 1)
        } catch {
            if isOutOfRoom { throw VoiceLoadError.storageFull }
        }
    }

    static func isShortOfStorage(free: Int64?) -> Bool {
        free.map { $0 < storageNeeded } ?? false
    }

    private var isOutOfRoom: Bool {
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        return Self.isShortOfStorage(free: (try? directory.resourceValues(forKeys: [key]))?.volumeAvailableCapacityForImportantUsage)
    }

    /// FluidAudio needs a folder it can write to, so it gets one made of links into the app, and the voice
    /// isn't stored twice. The app's path changes with each update, so this is redone every launch. That
    /// also clears the 390 MB download earlier builds left here.
    static func link(_ pack: URL, into directory: URL) throws {
        try? FileManager.default.removeItem(at: directory)
        try mirror(pack, into: directory)
    }

    /// Only a compiled model or a file is linked, because FluidAudio can't list a folder that's a link.
    private static func mirror(_ source: URL, into target: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try files.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            files.fileExists(atPath: from.path, isDirectory: &isFolder)
            if isFolder.boolValue, !name.hasSuffix(".mlmodelc") {
                try mirror(from, into: to)
            } else if rewritten.contains(name) {
                try files.copyItem(at: from, to: to)
            } else {
                try files.createSymbolicLink(at: to, withDestinationURL: from)
            }
        }
    }

    /// Always at the model's own pace. Its speed setting squeezes every sound, and at twice the speed that
    /// slurs the words, so `EngineVoiceOutput` speeds up the finished audio instead.
    func speech(for text: String) async throws -> VoiceSpeech {
        do {
            let spoken = SpokenText.prepared(text)
            let result = try await manager.synthesizeDetailed(text: spoken, voice: Self.voice, speed: 1)
            let kept = SpokenAudio.kept(result.samples)
            let marks = VoiceTiming.marks(
                text: text, said: result.normalizedText, phonemes: result.phonemes,
                durations: result.predictedDurations.map(Int.init), kept: kept
            )
            return VoiceSpeech(samples: Array(result.samples[kept]), marks: marks)
        } catch KokoroAneError.inputProcessingFailed {
            // Nothing in it can be said, like a line of emoji, so there's nothing to hand to another voice.
            return VoiceSpeech(samples: [])
        }
    }
}

/// Plays Kokoro's 24 kHz mono audio, faster or slower without changing the pitch.
@MainActor
final class EngineVoiceOutput: VoiceOutput {
    private static let sampleRate = 24_000.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pace = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: EngineVoiceOutput.sampleRate, channels: 1)
    private var total = 0

    init() {
        engine.attach(player)
        engine.attach(pace)
        engine.connect(player, to: pace, format: format)
        engine.connect(pace, to: engine.mainMixerNode, format: format)
    }

    var playedFraction: Double {
        guard total > 0, let time = player.lastRenderTime,
              let played = player.playerTime(forNodeTime: time)
        else { return 0 }
        return Double(played.sampleTime) / Double(total)
    }

    func play(_ samples: [Float], rate: Double, onDone: @escaping @MainActor @Sendable () -> Void) throws {
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw AudioOutputError.noBuffer }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        #if os(iOS)
        // Without this, the ring switch silences Listen.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        if !engine.isRunning { try engine.start() }
        total = samples.count
        pace.rate = Float(rate)
        // At normal speed the audio is left exactly as the model made it.
        pace.bypass = rate == 1
        // Sendable, so the closure isn't taken for main-actor code: the audio queue calls it.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            Task { @MainActor in onDone() }
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.play()
    }

    func stop() {
        total = 0
        player.stop()
        // Otherwise the end of what it was holding plays at the start of the next sentence.
        pace.reset()
    }

    private enum AudioOutputError: Error {
        case noBuffer
    }
}
