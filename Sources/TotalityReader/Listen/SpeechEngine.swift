import AVFoundation

public struct ListenVoice: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let language: String
}

/// Speaks one piece of text at a time. Speech stays on the device.
@MainActor
public protocol SpeechEngine: AnyObject {
    var onFinish: (() -> Void)? { get set }
    /// Called as each word starts, with how far into the text it is, in UTF-16 units.
    var onWord: ((Int) -> Void)? { get set }
    /// Something the person should see while speech can't start yet. Nil clears it.
    var onStatus: ((String?) -> Void)? { get set }
    func speak(_ text: String, speed: Double, voice: String?)
    /// A hint at what comes next, so it can start straight after this sentence. Nil drops anything held.
    func prepare(_ text: String?, speed: Double, voice: String?)
    func pause()
    func resume()
    func stop()
    func voices() -> [ListenVoice]
}

public extension SpeechEngine {
    func prepare(_ text: String?, speed: Double, voice: String?) {}
}

@MainActor
public final class SystemSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    public var onFinish: (() -> Void)?
    public var onWord: ((Int) -> Void)?
    public var onStatus: ((String?) -> Void)?
    /// Tests set this to zero so they make no sound.
    var volume: Float = 1

    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, speed: Double, voice: String?) {
        #if os(iOS)
        // Without this, the ring switch silences Listen.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Self.rate(forSpeed: speed)
        utterance.volume = volume
        utterance.voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        self.utterance = utterance
        synthesizer.speak(utterance)
    }

    static func rate(forSpeed speed: Double) -> Float {
        min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
    }

    public func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    public func resume() {
        synthesizer.continueSpeaking()
    }

    public func stop() {
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    public func voices() -> [ListenVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .map { ListenVoice(id: $0.identifier, name: $0.name, language: $0.language) }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    // The delegate can fire off the main actor, and after a stop has already moved on. The identity
    // checks drop anything that belongs to an earlier utterance.
    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance
    ) {
        let speaking = ObjectIdentifier(utterance)
        let offset = characterRange.location
        Task { @MainActor in
            guard let current = self.utterance, ObjectIdentifier(current) == speaking else { return }
            self.onWord?(offset)
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.utterance, ObjectIdentifier(current) == finished else { return }
            self.utterance = nil
            self.onFinish?()
        }
    }
}
