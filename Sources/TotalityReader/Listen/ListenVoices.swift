import Foundation

/// Listen's voice: the natural one, with the system voice as its backup, and the only voice on iOS 17
/// and macOS 14. The controller doesn't know which is speaking.
@MainActor
public final class ListenVoices: SpeechEngine {
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
                output: EngineVoiceOutput()
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

    public func speak(_ text: String, speed: Double) {
        self.speed = speed
        if let natural, !naturalFailed {
            speaking = natural
            natural.speak(text, speed: speed)
        } else {
            speaking = system
            system.speak(text, speed: speed)
        }
    }

    public func prepare(_ text: String?, speed: Double) {
        natural?.prepare(naturalFailed ? nil : text, speed: speed)
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

    /// Listening carries on in the system voice, because a voice that didn't load shouldn't end the book.
    private func fellBack(_ text: String) {
        naturalFailed = true
        onStatus?("The natural voice didn't load, so this is the system voice.")
        speaking = system
        system.speak(text, speed: speed)
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
