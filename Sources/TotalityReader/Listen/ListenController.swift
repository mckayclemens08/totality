import Foundation
import Observation

public struct ListenTrack: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let script: ListenScript
    public let startOffset: Int

    /// Nil when there is nothing to say.
    public init?(id: UUID, title: String, text: String, startOffset: Int = 0) {
        self.init(id: id, title: title, script: ListenScript(text: text), startOffset: startOffset)
    }

    /// Nil when there is nothing to say.
    public init?(id: UUID, title: String, script: ListenScript, startOffset: Int = 0) {
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
    /// Something asked for that's still being read and split. The bar shows it straight away, because
    /// a long book takes seconds to get ready and a button that does nothing for that long looks broken.
    public struct Opening: Equatable, Sendable {
        public let id: UUID
        public let title: String
        fileprivate let token = UUID()
    }

    public static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    public private(set) var current: ListenTrack?
    public private(set) var opening: Opening?
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

    /// True while the bar should show: something is playing, or on its way.
    public var isActive: Bool {
        current != nil || opening != nil
    }

    /// Shows the bar for something that's still being got ready, and starts the voice loading meanwhile.
    /// Whatever was playing stops, its place saved, and the queue stays, as when one track replaces another.
    public func open(_ id: UUID, title: String) -> Opening {
        if current != nil {
            engine.stop()
            engine.prepare(nil)
            reportPosition()
            current = nil
            sentence = 0
            isPaused = false
            restartOnResume = false
        }
        let opening = Opening(id: id, title: title)
        self.opening = opening
        engine.warmUp(speakingSoon: true)
        return opening
    }

    /// Plays what was opened, unless it was stopped or something else was opened since.
    public func play(_ track: ListenTrack, opened: Opening) {
        guard opening == opened else { return }
        play(track)
    }

    /// What was opened has nothing to read, so the bar goes again.
    public func cancel(_ opened: Opening) {
        if opening == opened { opening = nil }
    }

    /// Loads the voice ahead of time, for when Listen is likely soon.
    public func warmUp() {
        engine.warmUp(speakingSoon: false)
    }

    public var progress: Double {
        current?.script.progress(at: sentence, spoken: spoken) ?? 0
    }

    public func play(_ track: ListenTrack) {
        opening = nil
        current = track
        sentence = track.script.index(at: track.startOffset)
        speakCurrent()
    }

    public func enqueue(_ track: ListenTrack) {
        if current == nil, opening == nil { play(track) } else { queue.append(track) }
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
        jump(to: sentence + count)
    }

    /// Reads from a sentence, playing if it was paused, because that's what tapping one asks for.
    public func jump(to index: Int) {
        guard let track = current else { return }
        sentence = min(max(0, index), track.script.sentences.count - 1)
        speakCurrent()
    }

    public func setSpeed(_ speed: Double) {
        self.speed = speed
        settingChanged()
    }

    public func stop() {
        engine.stop()
        engine.prepare(nil)
        reportPosition()
        current = nil
        opening = nil
        queue = []
        sentence = 0
        isPaused = false
        restartOnResume = false
    }

    /// Drops an item that no longer exists, so its text does not stay in memory or keep playing.
    public func remove(_ id: UUID) {
        queue.removeAll { $0.id == id }
        if opening?.id == id { opening = nil }
        guard current?.id == id else { return }
        engine.stop()
        engine.prepare(nil)
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
        engine.prepare(next)
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
