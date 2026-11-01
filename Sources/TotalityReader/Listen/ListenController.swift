import Foundation
import Observation

public struct ListenTrack: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let script: ListenScript
    public let startOffset: Int

    /// Nil when there is nothing to say.
    public init?(id: UUID, title: String, text: String, startOffset: Int = 0) {
        let script = ListenScript(text: text)
        guard !script.sentences.isEmpty else { return nil }
        self.id = id
        self.title = title
        self.script = script
        self.startOffset = startOffset
    }
}

/// Play, pause, speed, queue, and resume position for Listen. It moves behind a shared player
/// protocol when the Player module starts (docs/module-contracts.md).
@MainActor
@Observable
public final class ListenController {
    public static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    public private(set) var current: ListenTrack?
    public private(set) var queue: [ListenTrack] = []
    public private(set) var sentence = 0
    /// How far into the current sentence speech has reached. It only moves the bar, so a saved
    /// position still lands on the start of a sentence.
    public private(set) var spoken = 0
    public private(set) var isPaused = false
    public private(set) var speed = 1.0
    /// Why speech hasn't started, such as a voice still downloading.
    public private(set) var status: String?

    /// Called with the offset to resume from whenever that changes.
    public var onPosition: ((UUID, Int) -> Void)?

    private let engine: any SpeechEngine
    private var restartOnResume = false

    public init(engine: any SpeechEngine) {
        self.engine = engine
        engine.onFinish = { [weak self] in self?.sentenceFinished() }
        engine.onWord = { [weak self] in self?.spoken = $0 }
        engine.onStatus = { [weak self] in self?.status = $0 }
    }

    public var progress: Double {
        current?.script.progress(at: sentence, spoken: spoken) ?? 0
    }

    public func play(_ track: ListenTrack) {
        current = track
        sentence = track.script.index(at: track.startOffset)
        speakCurrent()
    }

    public func enqueue(_ track: ListenTrack) {
        if current == nil { play(track) } else { queue.append(track) }
    }

    public func togglePause() {
        guard current != nil else { return }
        if !isPaused {
            engine.pause()
            isPaused = true
        } else if restartOnResume {
            speakCurrent()
        } else {
            engine.resume()
            isPaused = false
        }
    }

    public func skip(by count: Int) {
        guard let track = current else { return }
        sentence = min(max(0, sentence + count), track.script.sentences.count - 1)
        speakCurrent()
    }

    public func setSpeed(_ speed: Double) {
        self.speed = speed
        settingChanged()
    }

    public func stop() {
        engine.stop()
        engine.prepare(nil, speed: speed)
        reportPosition()
        current = nil
        queue = []
        sentence = 0
        isPaused = false
        restartOnResume = false
    }

    /// Drops an item that no longer exists, so its text does not stay in memory or keep playing.
    public func remove(_ id: UUID) {
        queue.removeAll { $0.id == id }
        guard current?.id == id else { return }
        engine.stop()
        engine.prepare(nil, speed: speed)
        current = nil
        sentence = 0
        isPaused = false
        restartOnResume = false
        if !queue.isEmpty { play(queue.removeFirst()) }
    }

    // A setting only reaches the engine with a new utterance, so the sentence restarts.
    private func settingChanged() {
        guard current != nil else { return }
        if isPaused { restartOnResume = true } else { speakCurrent() }
    }

    private func speakCurrent() {
        guard let track = current else { return }
        isPaused = false
        restartOnResume = false
        spoken = 0
        engine.stop()
        reportPosition()
        engine.speak(track.script.sentences[sentence].text, speed: speed)
        let next = sentence + 1 < track.script.sentences.count ? track.script.sentences[sentence + 1].text : nil
        engine.prepare(next, speed: speed)
    }

    private func reportPosition() {
        guard let track = current else { return }
        onPosition?(track.id, track.script.sentences[sentence].offset)
    }

    private func sentenceFinished() {
        guard let track = current else { return }
        if sentence + 1 < track.script.sentences.count {
            sentence += 1
            speakCurrent()
            return
        }
        // Finished, so the next listen starts from the top.
        onPosition?(track.id, 0)
        current = nil
        sentence = 0
        if !queue.isEmpty { play(queue.removeFirst()) }
    }
}
