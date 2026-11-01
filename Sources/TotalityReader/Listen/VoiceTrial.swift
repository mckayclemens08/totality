@preconcurrency import Darwin
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Trial only: makes speech over and over and prints how it went, so the natural voice can be measured
/// on a real device. It needs a launch argument only developer tools can pass, and it uses no one's
/// content. Remove it if the natural voice ships.
///
/// `-voiceTrial 1000` makes 1,000 sentences as fast as it can. `-voiceListen 12` reads aloud for 12
/// minutes through the real controller and speaker, timing the silence before each sentence.
@available(iOS 18, macOS 15, *)
public enum VoiceTrial {
    private static let sentences = [
        "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
        "Mr. Bennet replied that he had not.",
        "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters.",
        "Call me Ishmael.",
        "Some years ago, never mind how long precisely, having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world.",
        "On March 14, 2026, Dr. Okafor paid $1,250 for three tickets to Lisbon, and the flight left at 7:45 in the morning.",
        "\"Where are you going?\" she asked.",
        "The committee reviewed 17 proposals, approved 4, and sent the rest back for changes before the end of the quarter.",
    ]

    public static func runIfAsked() async {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-voiceListen"), flag + 1 < arguments.count,
           let minutes = Int(arguments[flag + 1]) {
            await listen(minutes: minutes)
            return
        }
        guard let flag = arguments.firstIndex(of: "-voiceTrial"), flag + 1 < arguments.count,
              let calls = Int(arguments[flag + 1]), let directory = ListenVoices.voiceDirectory()
        else { return }
        #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        #endif
        let voice = KokoroSynthesizer(directory: directory)
        var start = Date()
        do {
            try await voice.prepare()
            say(String(format: "prepared in %.1fs footprint %.0f MB", Date().timeIntervalSince(start), footprint()))
            var (audio, making, peak, slowest) = (0.0, 0.0, 0.0, 0.0)
            for call in 1...calls {
                let text = sentences[call % sentences.count]
                start = Date()
                let samples = try await voice.samples(for: text, voice: "kokoro.af_heart", speed: 1)
                let took = Date().timeIntervalSince(start)
                let seconds = Double(samples.count) / 24_000
                audio += seconds
                making += took
                peak = max(peak, footprint())
                slowest = max(slowest, took / seconds)
                say(String(
                    format: "%d %.1fs audio in %.2fs footprint %.0f MB thermal %d",
                    call, seconds, took, footprint(), ProcessInfo.processInfo.thermalState.rawValue
                ))
            }
            say(String(
                format: "DONE %d calls, %.0fs audio in %.0fs (%.1fx), peak %.0f MB, worst %.2f of real time",
                calls, audio, making, audio / making, peak, slowest
            ))
        } catch {
            say("FAILED \(error)")
        }
    }

    @MainActor
    private static func listen(minutes: Int) async {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        let book = Array(repeating: sentences.joined(separator: " "), count: 500).joined(separator: " ")
        guard let track = ListenTrack(id: UUID(), title: "Trial", text: book) else { return }
        let voices = TimedVoices()
        let listen = ListenController(engine: voices)
        listen.setVoice("kokoro.af_heart")
        listen.play(track)
        say("listening, \(track.script.sentences.count) sentences")
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        while Date() < end {
            try? await Task.sleep(for: .seconds(15))
            say(String(
                format: "sentence %d footprint %.0f MB thermal %d %@ status %@",
                listen.sentence, footprint(), ProcessInfo.processInfo.thermalState.rawValue, device(),
                listen.status ?? "none"
            ))
        }
        let gaps = voices.gaps.dropFirst()
        say(String(
            format: "DONE first audio %.2fs, %d gaps, worst %.2fs, over a second %d, peak %.0f MB",
            voices.gaps.first ?? 0, gaps.count, gaps.max() ?? 0, gaps.filter { $0 > 1 }.count, voices.peak
        ))
        listen.stop()
    }

    @MainActor
    private static func device() -> String {
        #if canImport(UIKit)
        let state = UIApplication.shared.applicationState == .active ? "open" : "background"
        return "\(state) battery \(Int(UIDevice.current.batteryLevel * 100))"
        #else
        return "mac"
        #endif
    }

    /// Times from asking for a sentence to its audio starting.
    @MainActor
    private final class TimedVoices: SpeechEngine {
        var onFinish: (() -> Void)? {
            didSet { inner.onFinish = onFinish }
        }
        var onWord: ((Int) -> Void)?
        var onStatus: ((String?) -> Void)? {
            didSet { inner.onStatus = onStatus }
        }
        private(set) var gaps: [Double] = []
        private(set) var peak = 0.0
        private let inner = ListenVoices()
        private var asked: Date?

        init() {
            inner.onWord = { [weak self] offset in self?.heard(offset) }
        }

        private func heard(_ offset: Int) {
            if let asked {
                gaps.append(Date().timeIntervalSince(asked))
                say(String(format: "gap %.2fs", gaps[gaps.count - 1]))
                self.asked = nil
            }
            peak = max(peak, footprint())
            onWord?(offset)
        }

        func speak(_ text: String, speed: Double, voice: String?) {
            asked = Date()
            inner.speak(text, speed: speed, voice: voice)
        }

        func prepare(_ text: String?, speed: Double, voice: String?) {
            inner.prepare(text, speed: speed, voice: voice)
        }

        func pause() { inner.pause() }
        func resume() { inner.resume() }
        func stop() { inner.stop() }
        func voices() -> [ListenVoice] { inner.voices() }
    }

    /// Kept in a file too, so a dropped connection to the device doesn't lose the result.
    private static func say(_ line: String) {
        print("[voice-trial] \(line)")
        fflush(stdout)
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let log = folder.appendingPathComponent("voice-trial.log")
        guard let data = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n".data(using: .utf8) else { return }
        if let file = try? FileHandle(forWritingTo: log) {
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
            try? file.close()
        } else {
            try? data.write(to: log)
        }
    }

    /// The figure iOS uses to decide when an app is taking too much memory.
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
