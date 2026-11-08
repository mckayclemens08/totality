import AVFoundation
import AVKit
import SwiftUI
import TotalityCore
import TotalityUI
import UniformTypeIdentifiers

/// Feeds AVPlayer a sealed movie a piece at a time, opening each piece as it's asked for. Nothing is
/// written out in plain form, and only the pieces being played are ever open in memory.
final class SealedMovieLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "totality-sealed"
    private let reader: ChunkedCipher.Reader
    private let type: String
    /// Concurrent, so a seek isn't held up behind a request for the rest of the file.
    let queue = DispatchQueue(label: "app.totality.photos.movie", attributes: .concurrent)

    init(reader: ChunkedCipher.Reader, type: String) {
        self.reader = reader
        self.type = type
    }

    /// A player item for the movie. The loader must be kept for as long as the item plays.
    func playerItem(for id: UUID) -> AVPlayerItem {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://movie/\(id.uuidString.lowercased()).mov")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return AVPlayerItem(asset: asset)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == Self.scheme else { return false }
        queue.async { self.serve(request) }
        return true
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) {
        if let information = request.contentInformationRequest {
            information.contentType = type
            information.contentLength = Int64(reader.plainLength)
            information.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return
        }
        let start = Int(data.currentOffset > 0 ? data.currentOffset : data.requestedOffset)
        let end = data.requestsAllDataToEndOfResource ? reader.plainLength : min(reader.plainLength, Int(data.requestedOffset) + data.requestedLength)
        var offset = start
        do {
            while offset < end {
                if request.isCancelled { return }
                let piece = try reader.read(offset..<min(end, offset + ChunkedCipher.chunkSize))
                guard !piece.isEmpty else { break }
                data.respond(with: piece)
                offset += piece.count
            }
            request.finishLoading()
        } catch {
            request.finishLoading(with: error)
        }
    }
}

/// A video from the library, opened on the device and played with the system's controls.
struct SealedVideoView: View {
    let model: PhotosModel
    let item: PhotoItem
    @State private var player: AVPlayer?
    @State private var loader: SealedMovieLoader?
    @State private var failed = false

    var body: some View {
        let theme = Theme.current
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                PhotosMessage(systemImage: "video.slash", title: "This video couldn't be opened",
                              detail: "It may still be downloading on another device, or the connection dropped. Try again in a moment.")
            } else {
                VStack(spacing: Space.s3) {
                    if let thumbnail = model.cachedThumbnail(item) {
                        Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                    }
                    ProgressView("Opening the video").foregroundStyle(theme.textSecondary.color)
                }
            }
        }
        .task(id: item.id) {
            do {
                let reader = try await model.movie(item)
                let loader = SealedMovieLoader(reader: reader, type: item.details.type)
                self.loader = loader
                player = AVPlayer(playerItem: loader.playerItem(for: item.id))
            } catch is CancellationError {
            } catch {
                failed = true
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// A Live Photo's movement, played over its still while the person holds it.
struct LiveMotionView: View {
    let model: PhotosModel
    let item: PhotoItem
    @State private var player: AVQueuePlayer?
    @State private var loader: SealedMovieLoader?

    var body: some View {
        Group {
            if let player {
                PlayerLayer(player: player)
            }
        }
        .allowsHitTesting(false)
        .task(id: item.id) {
            guard let reader = try? await model.movie(item) else { return }
            let loader = SealedMovieLoader(reader: reader, type: AVFileType.mov.rawValue)
            self.loader = loader
            let player = AVQueuePlayer(playerItem: loader.playerItem(for: item.id))
            player.isMuted = false
            player.play()
            self.player = player
        }
        .onDisappear { player?.pause() }
    }
}

#if os(iOS)
/// The movie with no controls, the way a Live Photo plays.
struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    final class View: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let view = View()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: View, context: Context) {
        view.playerLayer.player = player
    }
}
#else
struct PlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
#endif
