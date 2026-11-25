import AVFoundation
import ImageIO
import SwiftUI
import TotalityUI

/// Loads one photo or clip for a view, with its loading and error states.
@MainActor
@Observable
final class MediaLoad {
    enum State: Equatable { case loading, ready(Data), failed(String) }
    private(set) var state: State = .loading

    func load(_ item: PostMedia, from model: SocialModel) async {
        if case .ready = state { return }
        state = .loading
        do { state = .ready(try await model.mediaData(item)) } catch {
            state = .failed((error as? SocialError)?.message ?? "This didn't load.")
        }
    }

    func retry() { state = .loading }
}

enum PhotoDecode {
    /// A screen-sized image from a posted JPEG, never the full file decoded.
    static func image(_ data: Data, side: Int = 1200) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// One posted photo, filling its frame. A soft blank while it loads; a plain note and a retry if it can't.
struct PostPhoto: View {
    let model: SocialModel
    let item: PostMedia
    var side = 1200
    @State private var load = MediaLoad()

    var body: some View {
        let theme = Theme.current
        ZStack {
            Rectangle().fill(theme.surface.color)
            switch load.state {
            case .loading:
                Image(systemName: "photo").font(Typeface.title).foregroundStyle(theme.textTertiary.color)
                    .accessibilityLabel("Photo loading")
            case .ready(let data):
                if let image = PhotoDecode.image(data, side: side) {
                    Image(image, scale: 1, label: Text("Photo")).resizable().scaledToFill()
                } else {
                    failure("This photo couldn't be shown.")
                }
            case .failed(let message):
                failure(message)
            }
        }
        .clipped()
        .task(id: load.state == .loading) { if load.state == .loading { await load.load(item, from: model) } }
    }

    private func failure(_ message: String) -> some View {
        let theme = Theme.current
        return Button { load.retry() } label: {
            VStack(spacing: Space.s2) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).multilineTextAlignment(.center)
                Text("Tap to try again").foregroundStyle(theme.accent.color)
            }
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
            .padding(Space.s3)
        }
        .buttonStyle(SoftPress())
    }
}

/// A post's photos, one at a time, swiped sideways, with page dots under them (the approved post canvas).
struct PostPhotos: View {
    let model: SocialModel
    let photos: [PostMedia]
    var height: CGFloat = 330
    @State private var page: Int? = 0

    var body: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        VStack(spacing: Space.s2) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, item in
                        PostPhoto(model: model, item: item)
                            .containerRelativeFrame(.horizontal)
                            .frame(height: height)
                            .id(index)
                            .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            .frame(height: height)
            .clipShape(shape)
            if photos.count > 1 {
                HStack(spacing: Space.s1 + 2) {
                    ForEach(photos.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == (page ?? 0) ? theme.accent.color : theme.textTertiary.color)
                            .frame(width: index == (page ?? 0) ? Space.s4 : 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Photo \((page ?? 0) + 1) of \(photos.count)")
            }
        }
    }
}

/// Plays one clip from memory. Nothing is written to disk, so a sealed clip stays only in this app.
@MainActor
@Observable
final class ClipPlayer {
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var length: Double = 0
    private(set) var problem: String?

    func toggle(_ data: Data) {
        if playing { pause(); return }
        do {
            if player == nil {
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                player = try AVAudioPlayer(data: data)
                length = player?.duration ?? 0
            }
            problem = nil
            player?.play()
            playing = true
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let player = self.player else { return }
                    self.position = player.currentTime
                    if !player.isPlaying { self.playing = false; if player.currentTime == 0 { self.position = 0 }; return }
                }
            }
        } catch {
            problem = "This clip couldn't be played."
        }
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        position = player.currentTime
    }

    func pause() {
        player?.pause()
        playing = false
        ticker?.cancel()
    }

    func stop() {
        pause()
        player = nil
    }
}

/// An audio post's card: the tinted panel from the approved canvas, with play and pause, and its progress.
struct AudioCard: View {
    let model: SocialModel
    let item: PostMedia
    @State private var load = MediaLoad()
    @State private var player = ClipPlayer()

    var body: some View {
        let theme = Theme.current
        let total = player.length > 0 ? player.length : (item.duration ?? 0)
        VStack(alignment: .leading, spacing: Space.s3) {
            Label("Audio", systemImage: "mic").font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.accent.color)
            HStack(spacing: Space.s3) {
                Button {
                    if case .ready(let data) = load.state { player.toggle(data) } else { load.retry() }
                } label: {
                    ZStack {
                        Circle().fill(theme.accent.color)
                        if load.state == .loading {
                            ProgressView().tint(theme.accentOn.color)
                        } else {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                                .font(Typeface.title).foregroundStyle(theme.accentOn.color)
                        }
                    }
                    .frame(width: Space.s7 + Space.s3, height: Space.s7 + Space.s3)
                }
                .buttonStyle(SoftPress())
                .disabled(load.state == .loading)
                .accessibilityLabel(player.playing ? "Pause" : "Play")
                VStack(alignment: .leading, spacing: Space.s2) {
                    ProgressTrack(fraction: total > 0 ? player.position / total : 0) { player.seek(to: $0) }
                        .accessibilityElement()
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(ClipTime.text(player.position)) of \(ClipTime.text(total))")
                    HStack {
                        Text(ClipTime.text(player.position))
                        Spacer()
                        Text(ClipTime.text(total))
                    }
                    .font(Typeface.caption.monospacedDigit())
                    .foregroundStyle(theme.textSecondary.color)
                }
            }
            if case .failed(let message) = load.state {
                Text("\(message) Tap play to try again.").font(Typeface.caption).foregroundStyle(theme.danger.color)
            } else if let problem = player.problem {
                Text(problem).font(Typeface.caption).foregroundStyle(theme.danger.color)
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.highlight.color, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .task(id: load.state == .loading) { if load.state == .loading { await load.load(item, from: model) } }
        .onDisappear { player.stop() }
    }
}

/// A thin progress line you can tap or drag along to move through a clip. Flat, never sunken.
struct ProgressTrack: View {
    let fraction: Double
    let onSeek: (Double) -> Void

    var body: some View {
        let theme = Theme.current
        GeometryReader { geo in
            let f = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(theme.highlightStrong.color)
                Capsule().fill(theme.accent.color).frame(width: geo.size.width * f)
                Circle().fill(theme.accent.color).frame(width: Space.s4, height: Space.s4)
                    .offset(x: geo.size.width * f - Space.s2)
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { onSeek($0.location.x / max(geo.size.width, 1)) })
        }
        .frame(height: Space.s5)
    }
}

/// The top of a grid card for a post with media: its first photo with a count, or the audio tile.
struct GridCover: View {
    let model: SocialModel
    let post: SocialPost

    var body: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        if let video = post.video {
            // The grid shows a video's cover and its length; it plays once the post is open.
            Group {
                if let cover = post.photos.first {
                    PostPhoto(model: model, item: cover, side: 600)
                } else {
                    Rectangle().fill(theme.surface.color)
                }
            }
            .aspectRatio(0.8, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(shape)
            .overlay {
                ZStack {
                    Circle().fill(theme.accent.color)
                    Image(systemName: "play.fill").font(Typeface.callout).foregroundStyle(theme.accentOn.color)
                }
                .frame(width: Space.s6, height: Space.s6)
            }
            .overlay(alignment: .topTrailing) {
                VideoChip(text: ClipTime.text(video.duration ?? 0), systemImage: "video").padding(Space.s2)
            }
            .accessibilityElement()
            .accessibilityLabel("Video post, \(ClipTime.text(video.duration ?? 0))")
        } else if let first = post.photos.first {
            let ratio = Double(first.height ?? 1) / Double(max(first.width ?? 1, 1))
            PostPhoto(model: model, item: first, side: 600)
                .aspectRatio(1 / min(max(ratio, 0.75), 1.33), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    if post.photos.count > 1 {
                        Label("\(post.photos.count)", systemImage: "square.on.square")
                            .font(Typeface.micro.weight(.semibold))
                            .foregroundStyle(theme.textPrimary.color)
                            .padding(.horizontal, Space.s2).padding(.vertical, 2)
                            .background(theme.surface.color.opacity(0.85), in: Capsule())
                            .padding(Space.s2)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(post.photos.count == 1 ? "Photo post" : "Photo post, \(post.photos.count) photos")
        } else if let audio = post.audio {
            HStack(spacing: Space.s2) {
                ZStack {
                    Circle().fill(theme.accent.color)
                    Image(systemName: "play.fill").font(Typeface.micro).foregroundStyle(theme.accentOn.color)
                }
                .frame(width: Space.s5, height: Space.s5)
                Label(ClipTime.text(audio.duration ?? 0), systemImage: "mic")
                    .font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.accent.color)
                Spacer(minLength: 0)
            }
            .padding(Space.s3)
            .background(theme.highlight.color, in: shape)
            .accessibilityElement()
            .accessibilityLabel("Audio post, \(ClipTime.text(audio.duration ?? 0))")
        }
    }
}

/// A post's media in a feed or opened: a video playing muted, photos swiped through, or the audio card.
struct PostMediaView: View {
    let model: SocialModel
    let post: SocialPost
    var photoHeight: CGFloat = 330

    var body: some View {
        if let video = post.video {
            VideoCard(model: model, item: video, cover: post.photos.first, height: photoHeight)
        } else if !post.photos.isEmpty {
            PostPhotos(model: model, photos: post.photos, height: photoHeight)
        } else if let audio = post.audio {
            AudioCard(model: model, item: audio)
        }
    }
}
