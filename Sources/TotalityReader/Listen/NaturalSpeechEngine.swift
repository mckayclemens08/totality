import AVFoundation
import FluidAudio

/// Turns text into audio samples. Nothing here leaves the device: only the model is ever downloaded.
protocol VoiceSynthesizer: Sendable {
    func prepare() async throws
    func samples(for text: String, speed: Double) async throws -> [Float]
}

/// Plays one run of samples at a time.
@MainActor
protocol VoiceOutput: AnyObject {
    /// How far through the current samples playback has got, from 0 to 1.
    var playedFraction: Double { get }
    func play(_ samples: [Float], onDone: @escaping @MainActor @Sendable () -> Void) throws
    func pause()
    func resume()
    func stop()
}

/// Reads with a neural voice that runs on this device. Making a sentence takes about a second on a
/// phone, so the next one is made ahead of time. Otherwise every sentence would end in a long pause.
@MainActor
final class NaturalSpeechEngine: SpeechEngine {
    /// The model gives no word timing, so the bar is moved by how much of the audio has played.
    private static let positionPause = Duration.milliseconds(250)

    var onFinish: (() -> Void)?
    var onWord: ((Int) -> Void)?
    var onStatus: ((String?) -> Void)?
    /// Called when speech couldn't be made, with the text that was lost.
    var onFailure: ((String) -> Void)?

    private let synthesizer: any VoiceSynthesizer
    private let output: any VoiceOutput
    private var isReady = false
    /// Shared and never cancelled, because skipping during a load shouldn't start it again.
    private var loading: Task<Void, any Error>?

    private struct Request: Equatable {
        let text: String
        let speed: Double
    }

    private var isPaused = false
    private var isPlaying = false
    private var isWaiting = false
    /// Moves on with every speak and stop, so work that finishes late can see it's out of date.
    private var turn = 0
    private var making: Task<Void, Never>?
    private var ahead: (request: Request, samples: Task<[Float], any Error>)?
    private var wanted: Request?
    private var position: Task<Void, Never>?

    init(synthesizer: any VoiceSynthesizer, output: any VoiceOutput) {
        self.synthesizer = synthesizer
        self.output = output
    }

    func speak(_ text: String, speed: Double) {
        stop()
        let current = turn
        let request = Request(text: text, speed: speed)
        let held = ahead?.request == request ? ahead?.samples : nil
        if held == nil { ahead?.samples.cancel() }
        ahead = nil
        wanted = nil
        let synthesizer = self.synthesizer
        let load = isReady ? nil : loading ?? Task { try await synthesizer.prepare() }
        loading = load
        if load != nil {
            isWaiting = true
            onStatus?("Getting the voice ready. This takes about a minute, or a few the first time.")
        }
        making = Task { [weak self] in
            do {
                try await load?.value
                let samples = if let held {
                    try await held.value
                } else {
                    try await synthesizer.samples(for: text, speed: speed)
                }
                self?.made(samples, text: text, turn: current)
            } catch {
                self?.failed(text, turn: current)
            }
        }
    }

    func prepare(_ text: String?, speed: Double) {
        guard let text else {
            ahead?.samples.cancel()
            ahead = nil
            wanted = nil
            return
        }
        let request = Request(text: text, speed: speed)
        guard ahead?.request != request else { return }
        ahead?.samples.cancel()
        ahead = nil
        wanted = request
        makeAhead()
    }

    /// Waits for the sentence being made, so the voice is only ever loaded once.
    private func makeAhead() {
        guard isReady, making == nil, let wanted else { return }
        self.wanted = nil
        let synthesizer = self.synthesizer
        ahead = (wanted, Task {
            try await synthesizer.samples(for: wanted.text, speed: wanted.speed)
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
        position?.cancel()
        position = nil
        isPlaying = false
        isPaused = false
        doneWaiting()
        output.stop()
    }

    /// One sentence's position, worked out from the audio. Offsets are UTF-16, the same as speech's.
    static func offset(forFraction fraction: Double, inTextOfLength length: Int) -> Int {
        Int(min(max(fraction, 0), 1) * Double(length))
    }

    func reportPosition(textLength: Int) {
        onWord?(Self.offset(forFraction: output.playedFraction, inTextOfLength: textLength))
    }

    private func made(_ samples: [Float], text: String, turn: Int) {
        guard turn == self.turn else { return }
        isReady = true
        making = nil
        doneWaiting()
        do {
            try output.play(samples) { [weak self] in self?.played(turn: turn) }
        } catch {
            failed(text, turn: turn)
            return
        }
        isPlaying = true
        if isPaused { output.pause() }
        let length = text.utf16.count
        position = Task { [weak self] in
            while !Task.isCancelled {
                self?.reportPosition(textLength: length)
                try? await Task.sleep(for: Self.positionPause)
            }
        }
        makeAhead()
    }

    private func played(turn: Int) {
        guard turn == self.turn else { return }
        position?.cancel()
        position = nil
        isPlaying = false
        onFinish?()
    }

    private func failed(_ text: String, turn: Int) {
        guard turn == self.turn, !Task.isCancelled else { return }
        making = nil
        isPlaying = false
        doneWaiting()
        onFailure?(text)
    }

    private func doneWaiting() {
        guard isWaiting else { return }
        isWaiting = false
        onStatus?(nil)
    }
}

/// Kokoro, through a pinned FluidAudio release. Models are checked against pinned hashes when they arrive.
@available(iOS 18, macOS 15, *)
final class KokoroSynthesizer: VoiceSynthesizer {
    private static let voice = "am_michael"

    private let manager: KokoroAneManager

    init(directory: URL) {
        // A word the model can't read is logged, so the log mustn't reach stderr. The system log keeps it private.
        AppLogger.mirrorsToConsole = false
        manager = KokoroAneManager(directory: directory, version: .v3)
    }

    func prepare() async throws {
        try await manager.initialize()
    }

    func samples(for text: String, speed: Double) async throws -> [Float] {
        let result = try await manager.synthesizeDetailed(text: text, voice: Self.voice, speed: Float(speed))
        return result.samples
    }
}

/// Plays Kokoro's 24 kHz mono audio.
@MainActor
final class EngineVoiceOutput: VoiceOutput {
    private static let sampleRate = 24_000.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: EngineVoiceOutput.sampleRate, channels: 1)
    private var total = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    var playedFraction: Double {
        guard total > 0, let time = player.lastRenderTime,
              let played = player.playerTime(forNodeTime: time)
        else { return 0 }
        return Double(played.sampleTime) / Double(total)
    }

    func play(_ samples: [Float], onDone: @escaping @MainActor @Sendable () -> Void) throws {
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
    }

    private enum AudioOutputError: Error {
        case noBuffer
    }
}
