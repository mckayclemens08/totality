import AVFoundation
import Foundation

/// Records a voice clip for a post, up to two minutes, as small mono AAC. The file sits in this app's
/// temporary folder only until it's read into memory, then it's deleted.
@MainActor
@Observable
final class AudioCapture {
    enum State: Equatable { case idle, recording, done, failed(String) }
    private(set) var state: State = .idle
    private(set) var elapsed: Double = 0
    private(set) var clip: Attachment?
    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var file: URL?

    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]

    func start() async {
        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Totality can't use the microphone. Turn it on in Settings, or upload an audio file instead.")
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            state = .failed("The microphone isn't available right now.")
            return
        }
        #endif
        discard()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            guard recorder.record(forDuration: MediaLimits.audioSeconds) else { throw SocialError.failed("") }
            self.recorder = recorder
            file = url
            state = .recording
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let recorder = self.recorder else { return }
                    if recorder.isRecording { self.elapsed = recorder.currentTime } else { self.finish(); return }
                }
            }
        } catch {
            state = .failed("Recording didn't start. Try again.")
        }
    }

    /// Stops and keeps what was recorded.
    func stop() {
        recorder?.stop()
        finish()
    }

    private func finish() {
        ticker?.cancel()
        guard state == .recording, let file else { return }
        let length = recorder?.currentTime ?? elapsed
        recorder = nil
        defer { try? FileManager.default.removeItem(at: file); self.file = nil }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            state = .failed("Nothing was recorded. Try again.")
            return
        }
        let duration = AVURLAssetDuration.seconds(data) ?? max(length, elapsed)
        guard data.count <= MediaLimits.fileBytes else { state = .failed("That clip is too big to post."); return }
        clip = Attachment(kind: .audio, data: data, duration: min(duration, MediaLimits.audioSeconds))
        state = .done
    }

    /// Uses a file picked from Files instead, re-encoded on this device and cut at two minutes.
    func pick(_ url: URL) async {
        discard()
        state = .recording
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let (data, duration) = try await Self.convert(url)
            guard data.count <= MediaLimits.fileBytes else { throw SocialError.refused("That clip is too big to post, even cut to two minutes.") }
            clip = Attachment(kind: .audio, data: data, duration: duration)
            state = .done
        } catch {
            state = .failed((error as? SocialError)?.message ?? "That file couldn't be used as audio.")
        }
    }

    func discard() {
        ticker?.cancel()
        recorder?.stop()
        recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        clip = nil
        elapsed = 0
        state = .idle
    }

    /// Re-encodes any audio file as AAC in an M4A, keeping at most the first two minutes. Re-encoding keeps
    /// only the sound, so the file's name, tags and artwork never leave the device.
    nonisolated static func convert(_ url: URL) async throws -> (Data, Double) {
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0 else { throw SocialError.failed("That file has no sound in it.") }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SocialError.failed("That file couldn't be used as audio.")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        let length = min(total, MediaLimits.audioSeconds)
        export.outputURL = out
        export.outputFileType = .m4a
        export.metadata = []
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in export.exportAsynchronously { done.resume() } }
        guard export.status == .completed else { throw SocialError.failed("That file couldn't be used as audio.") }
        return (try Data(contentsOf: out), length)
    }
}

/// A clip's length read from its bytes.
enum AVURLAssetDuration {
    static func seconds(_ data: Data) -> Double? {
        guard let player = try? AVAudioPlayer(data: data), player.duration > 0 else { return nil }
        return player.duration
    }
}
