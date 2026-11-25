import AVFoundation
import AVKit
import SwiftUI
import TotalityUI
#if os(iOS)
import UIKit
#endif

/// Fetches one video to a playable file, with its loading and error states.
@MainActor
@Observable
final class VideoLoad {
    enum State: Equatable { case waiting, loading, ready(URL), failed(String) }
    private(set) var state: State = .waiting

    func load(_ item: PostMedia, from model: SocialModel) async {
        switch state {
        case .ready, .loading: return
        default: break
        }
        state = .loading
        do { state = .ready(try await model.videoFile(item)) } catch {
            state = .failed((error as? SocialError)?.message ?? "This video didn't load.")
        }
    }

    func retry() { state = .waiting }
}

/// A player drawn straight into the view, with no controls of its own: the card decides what a tap does.
#if os(iOS)
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill = true

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
#else
struct PlayerSurface: View {
    let player: AVPlayer
    var fill = true
    var body: some View { VideoPlayer(player: player).allowsHitTesting(false) }
}
#endif

enum PlaybackSession {
    /// Muted video mixes with whatever else is playing; sound takes over like any player.
    static func use(sound: Bool) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if sound {
            try? session.setCategory(.playback)
        } else if session.category != .playback {
            try? session.setCategory(.ambient, options: .mixWithOthers)
        }
        try? session.setActive(true)
        #endif
    }
}

/// A small label over a video: its length, or whether the sound is on.
struct VideoChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        let theme = Theme.current
        Label(text, systemImage: systemImage)
            .font(Typeface.micro.weight(.semibold))
            .foregroundStyle(theme.textPrimary.color)
            .padding(.horizontal, Space.s2).padding(.vertical, 2)
            .background(theme.surface.color.opacity(0.85), in: Capsule())
    }
}

/// A video post in a feed: its cover until it's on screen and loaded, then it plays muted, over and over.
/// A tap turns the sound on or off; it pauses when it scrolls away.
struct VideoCard: View {
    let model: SocialModel
    let item: PostMedia
    let cover: PostMedia?
    var height: CGFloat = 260
    @State private var load = VideoLoad()
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var muted = true
    @State private var onScreen = false

    var body: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        ZStack {
            if let cover { PostPhoto(model: model, item: cover) } else { Rectangle().fill(theme.surface.color) }
            if let player { PlayerSurface(player: player) }
            if load.state == .loading { ProgressView().tint(theme.accent.color) }
            if case .failed(let message) = load.state {
                Button { load.retry() } label: {
                    VStack(spacing: Space.s1) {
                        Text(message)
                        Text("Tap to try again").foregroundStyle(theme.accent.color)
                    }
                    .font(Typeface.caption).foregroundStyle(theme.textPrimary.color)
                    .padding(Space.s3)
                    .background(theme.surface.color.opacity(0.9), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(SoftPress())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            VideoChip(text: ClipTime.text(item.duration ?? 0), systemImage: "video").padding(Space.s2)
        }
        .overlay(alignment: .topTrailing) {
            if player != nil {
                VideoChip(text: muted ? "Muted · tap for sound" : "Sound on", systemImage: muted ? "speaker.slash" : "speaker.wave.2")
                    .padding(Space.s2)
            }
        }
        .contentShape(shape)
        .onTapGesture {
            guard let player else { return }
            muted.toggle()
            PlaybackSession.use(sound: !muted)
            player.isMuted = muted
        }
        .accessibilityElement()
        .accessibilityLabel("Video, \(ClipTime.text(item.duration ?? 0))")
        .accessibilityValue(muted ? "Muted" : "Sound on")
        .accessibilityHint("Double-tap to turn the sound \(muted ? "on" : "off")")
        .accessibilityAddTraits(.isButton)
        .onAppear { onScreen = true; player?.play() }
        .onDisappear {
            onScreen = false
            player?.pause()
            if !muted { muted = true; player?.isMuted = true }
        }
        .task(id: load.state == .waiting && onScreen) {
            guard onScreen else { return }
            await load.load(item, from: model)
            start()
        }
    }

    private func start() {
        guard player == nil, case .ready(let url) = load.state else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        PlaybackSession.use(sound: false)
        if onScreen { queue.play() }
    }
}

/// A video with sound, played once, for an opened story. Says when it's ready and when it ends.
struct StoryVideo: View {
    let model: SocialModel
    let item: PostMedia
    let paused: Bool
    let onReady: () -> Void
    @State private var load = VideoLoad()
    @State private var player: AVPlayer?

    var body: some View {
        let theme = Theme.current
        ZStack {
            if let player { PlayerSurface(player: player, fill: false) }
            switch load.state {
            case .waiting, .loading: ProgressView().tint(theme.accent.color)
            case .failed(let message): Text(message).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            case .ready: EmptyView()
            }
        }
        .task {
            await load.load(item, from: model)
            guard case .ready(let url) = load.state else { return }
            let player = AVPlayer(url: url)
            PlaybackSession.use(sound: true)
            self.player = player
            player.play()
            onReady()
        }
        .onChange(of: paused) { _, paused in if paused { player?.pause() } else { player?.play() } }
        .onDisappear { player?.pause() }
    }
}
