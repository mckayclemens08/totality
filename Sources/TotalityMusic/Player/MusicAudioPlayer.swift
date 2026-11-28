import AVFoundation
import Foundation
import MediaPlayer
import Observation
import TotalityCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Plays uploaded audio (`AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioUnitTimePitch`, including
/// FLAC/ALAC/M4A/MP3/WAV) and OpenSubsonic streams (`AVPlayer`), with Lock Screen controls and
/// shared `AudioTransportCoordinator` arbitration.
@MainActor
@Observable
public final class MusicAudioPlayer {
    public private(set) var currentTrack: MusicTrack?
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var speed: Double = 1.0
    public private(set) var errorMessage: String?

    public static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    @ObservationIgnored public var onTrackFinished: (@MainActor () -> Void)?
    @ObservationIgnored public weak var audioFocus: AudioTransportCoordinator? {
        didSet {
            audioFocus?.registerPauseHandler(for: .player) { [weak self] in
                self?.pause()
            }
        }
    }

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var playerNode = AVAudioPlayerNode()
    @ObservationIgnored private var pitchNode = AVAudioUnitTimePitch()
    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var fileSampleRate: Double = 44_100
    @ObservationIgnored private var fileTotalFrames: AVAudioFramePosition = 0
    @ObservationIgnored private var seekFrameOffset: AVAudioFramePosition = 0
    @ObservationIgnored private var generationToken = UUID()

    @ObservationIgnored private var streamPlayer: AVPlayer?
    @ObservationIgnored private var streamEndObserver: NSObjectProtocol?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var artworkData: Data?

    public init() {
        setupEngine()
        setupRemoteCommands()
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    public func playLocalFile(url: URL, track: MusicTrack, artwork: Data?) {
        stopPlayback(clearTrack: false)
        errorMessage = nil
        currentTrack = track
        artworkData = artwork
        generationToken = UUID()
        let token = generationToken

        do {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            fileSampleRate = file.processingFormat.sampleRate
            fileTotalFrames = file.length
            duration = fileTotalFrames > 0 && fileSampleRate > 0 ? Double(fileTotalFrames) / fileSampleRate : track.duration
            currentTime = 0
            seekFrameOffset = 0

            engine.disconnectNodeInput(playerNode)
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: pitchNode, format: file.processingFormat)
            engine.connect(pitchNode, to: engine.mainMixerNode, format: file.processingFormat)
            pitchNode.rate = Float(speed)
            pitchNode.bypass = (speed == 1.0)

            if !engine.isRunning {
                try engine.start()
            }

            audioFocus?.claimFocus(for: .player, summary: summary(for: track, playing: true))
            scheduleLocalSegment(fromFrame: 0, token: token)
            playerNode.play()
            isPlaying = true
            startProgressTicker()
            publishNowPlaying()
        } catch {
            errorMessage = "Couldn't play \(track.title): \(error.localizedDescription)"
            isPlaying = false
            audioFocus?.releaseFocus(for: .player)
        }
    }

    public func playStream(url: URL, track: MusicTrack, artwork: Data?) {
        stopPlayback(clearTrack: false)
        errorMessage = nil
        currentTrack = track
        artworkData = artwork
        duration = track.duration
        currentTime = 0

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.rate = Float(speed)
        streamPlayer = player
        audioFocus?.claimFocus(for: .player, summary: summary(for: track, playing: true))

        streamEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finishCurrentTrack()
            }
        }
        player.play()
        if speed != 1.0 { player.rate = Float(speed) }
        isPlaying = true
        startProgressTicker()
        publishNowPlaying()
    }

    public func togglePause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            pause()
        } else {
            audioFocus?.claimFocus(for: .player, summary: summary(for: track, playing: true))
            if let streamPlayer {
                streamPlayer.play()
                if speed != 1.0 { streamPlayer.rate = Float(speed) }
                isPlaying = true
            } else if audioFile != nil {
                if !engine.isRunning { try? engine.start() }
                playerNode.play()
                isPlaying = true
            }
            startProgressTicker()
            publishNowPlaying()
        }
    }

    public func pause() {
        guard isPlaying else { return }
        playerNode.pause()
        streamPlayer?.pause()
        isPlaying = false
        progressTask?.cancel()
        progressTask = nil
        if let track = currentTrack {
            audioFocus?.updateSummary(summary(for: track, playing: false))
        }
        publishNowPlaying()
    }

    public func seek(to progressRatio: Double) {
        let clamped = min(1, max(0, progressRatio))
        guard duration > 0 else { return }
        let targetSeconds = clamped * duration
        if let streamPlayer {
            let cmTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            streamPlayer.seek(to: cmTime)
            currentTime = targetSeconds
        } else if let file = audioFile {
            let targetFrame = min(file.length, max(0, AVAudioFramePosition(targetSeconds * fileSampleRate)))
            generationToken = UUID()
            let token = generationToken
            let wasPlaying = isPlaying
            playerNode.stop()
            seekFrameOffset = targetFrame
            scheduleLocalSegment(fromFrame: targetFrame, token: token)
            if wasPlaying {
                if !engine.isRunning { try? engine.start() }
                playerNode.play()
            }
            currentTime = targetSeconds
        }
        publishNowPlaying()
    }

    public func setSpeed(_ newSpeed: Double) {
        speed = newSpeed
        pitchNode.rate = Float(newSpeed)
        pitchNode.bypass = (newSpeed == 1.0)
        if let streamPlayer, isPlaying {
            streamPlayer.rate = Float(newSpeed)
        }
        publishNowPlaying()
    }

    public func stop() {
        stopPlayback(clearTrack: true)
    }

    private func stopPlayback(clearTrack: Bool) {
        generationToken = UUID()
        progressTask?.cancel()
        progressTask = nil
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        audioFile = nil
        streamPlayer?.pause()
        streamPlayer = nil
        if let obs = streamEndObserver {
            NotificationCenter.default.removeObserver(obs)
            streamEndObserver = nil
        }
        isPlaying = false
        if clearTrack {
            currentTrack = nil
            artworkData = nil
            currentTime = 0
            duration = 0
            audioFocus?.releaseFocus(for: .player)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(pitchNode)
        engine.connect(playerNode, to: pitchNode, format: nil)
        engine.connect(pitchNode, to: engine.mainMixerNode, format: nil)
    }

    private func scheduleLocalSegment(fromFrame: AVAudioFramePosition, token: UUID) {
        guard let file = audioFile else { return }
        let remaining = fileTotalFrames - fromFrame
        guard remaining > 0 else {
            finishCurrentTrack()
            return
        }
        let count = AVAudioFrameCount(remaining)
        playerNode.scheduleSegment(
            file,
            startingFrame: fromFrame,
            frameCount: count,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generationToken == token else { return }
                self.finishCurrentTrack()
            }
        }
    }

    private func finishCurrentTrack() {
        isPlaying = false
        currentTime = duration
        progressTask?.cancel()
        progressTask = nil
        onTrackFinished?()
    }

    private func startProgressTicker() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isPlaying {
                self.refreshElapsedTime()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refreshElapsedTime() {
        if let streamPlayer {
            let seconds = streamPlayer.currentTime().seconds
            if seconds.isFinite && seconds >= 0 { currentTime = seconds }
            if let itemDuration = streamPlayer.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
        } else if audioFile != nil,
                  let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
                  fileSampleRate > 0 {
            let totalFrames = seekFrameOffset + playerTime.sampleTime
            currentTime = min(duration, max(0, Double(totalFrames) / fileSampleRate))
        }
        if let track = currentTrack {
            audioFocus?.updateSummary(summary(for: track, playing: isPlaying))
        }
    }

    private func summary(for track: MusicTrack, playing: Bool) -> NowPlayingSummary {
        NowPlayingSummary(
            module: .player,
            title: track.title,
            subtitle: track.subtitle,
            badge: track.source.audioBadge,
            isPlaying: playing,
            progress: progress
        )
    }

    private func setupRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == false { self?.togglePause() }
            }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePause()
            }
            return .success
        }
    }

    private func publishNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist.isEmpty ? track.source.displayName : track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
        ]
        #if canImport(UIKit)
        if let artworkData, let image = UIImage(data: artworkData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        #elseif canImport(AppKit)
        if let artworkData, let image = NSImage(data: artworkData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        #endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
