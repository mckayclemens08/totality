import Foundation

/// The voices Listen can use. A natural voice is an ordinary voice ID with a prefix, so the controller
/// doesn't need to know which engine is speaking.
@MainActor
public final class ListenVoices: SpeechEngine {
    nonisolated static let naturalPrefix = "kokoro."

    public var onFinish: (() -> Void)?
    public var onWord: ((Int) -> Void)?
    public var onStatus: ((String?) -> Void)?

    private let system: any SpeechEngine
    private let natural: NaturalSpeechEngine?
    private var speaking: (any SpeechEngine)?
    private var speed = 1.0
    /// Stays set until the app restarts, so a failed voice isn't tried again on every sentence.
    private var naturalFailed = false

    public convenience init() {
        var natural: NaturalSpeechEngine?
        if #available(iOS 18, macOS 15, *), let directory = Self.voiceDirectory() {
            natural = NaturalSpeechEngine(
                synthesizer: KokoroSynthesizer(directory: directory),
                output: EngineVoiceOutput(),
                voices: KokoroSynthesizer.voices
            )
        }
        self.init(system: SystemSpeechEngine(), natural: natural)
    }

    init(system: any SpeechEngine, natural: NaturalSpeechEngine?) {
        self.system = system
        self.natural = natural
        let engines: [any SpeechEngine] = natural.map { [system, $0] } ?? [system]
        for engine in engines {
            engine.onFinish = { [weak self] in self?.onFinish?() }
            engine.onWord = { [weak self] in self?.onWord?($0) }
            engine.onStatus = { [weak self] in self?.onStatus?($0) }
        }
        natural?.onFailure = { [weak self] text in self?.fellBack(text) }
    }

    public func speak(_ text: String, speed: Double, voice: String?) {
        self.speed = speed
        if let voice, voice.hasPrefix(Self.naturalPrefix), let natural {
            guard !naturalFailed else {
                speaking = system
                system.speak(text, speed: speed, voice: nil)
                return
            }
            speaking = natural
            natural.speak(text, speed: speed, voice: voice)
        } else {
            speaking = system
            system.speak(text, speed: speed, voice: voice)
        }
    }

    public func prepare(_ text: String?, speed: Double, voice: String?) {
        natural?.prepare(naturalFailed ? nil : text, speed: speed, voice: voice)
    }

    public func pause() {
        speaking?.pause()
    }

    public func resume() {
        speaking?.resume()
    }

    public func stop() {
        system.stop()
        natural?.stop()
        speaking = nil
    }

    public func voices() -> [ListenVoice] {
        (natural?.voices() ?? []) + system.voices()
    }

    /// Listening carries on in the system voice, because a voice that didn't load shouldn't end the book.
    private func fellBack(_ text: String) {
        naturalFailed = true
        onStatus?("The natural voice didn't load, so this is the system voice.")
        speaking = system
        system.speak(text, speed: speed, voice: nil)
    }

    /// Not backed up, because the model can be downloaded again and holds nothing of this person's.
    nonisolated static func voiceDirectory() -> URL? {
        guard var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        directory.appendPathComponent("Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }
}
