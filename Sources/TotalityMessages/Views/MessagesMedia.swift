import AVKit
import SwiftUI
import TotalityUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An image from bytes that were opened on this device.
struct OpenedImage: View {
    let data: Data

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        }
        #elseif canImport(AppKit)
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit()
        }
        #endif
    }
}

/// A photo in a chat: its small version, opened when it scrolls into view.
struct PhotoBubble: View {
    let message: ChatMessage
    let model: ChatModel
    let onOpen: () -> Void
    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        let theme = Theme.current
        let ratio: CGFloat = {
            if case .photo(let w?, let h?) = message.kind, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
            return 4.0 / 3.0
        }()
        Button(action: onOpen) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.md).fill(theme.surface.color)
                if let data {
                    OpenedImage(data: data)
                } else if failed {
                    Label("Photo didn't open", systemImage: "photo")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: 240, maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message.isOwn ? "Your photo" : "Photo from \(MessagesUsername.display(message.sender))")
        // Runs again once a photo you sent reaches the server: until then there's nothing to fetch.
        .task(id: "\(message.id)|\(message.state == .sent)") {
            guard message.state == .sent else { return }
            data = await model.photo(message, thumbnail: true)
            failed = data == nil
        }
    }
}

/// A photo full size, opened on this device and kept only in memory.
struct PhotoViewer: View {
    let message: ChatMessage
    let model: ChatModel
    let onClose: () -> Void
    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ZStack {
                theme.bg.color.ignoresSafeArea()
                if let data {
                    OpenedImage(data: data).padding(Space.s3)
                } else if failed {
                    MessagesStateView(systemImage: "photo", title: "This photo didn't open", detail: "Check your connection and try again.")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(message.isOwn ? "Your photo" : MessagesUsername.display(message.sender))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
        }
        .tint(theme.accent.color)
        .task {
            data = await model.photo(message, thumbnail: false)
            failed = data == nil
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// A short video in a chat: its still, with a play mark and its length.
struct VideoBubble: View {
    let message: ChatMessage
    let model: ChatModel
    let onOpen: () -> Void
    @State private var still: Data?

    var body: some View {
        let theme = Theme.current
        Button(action: onOpen) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.md).fill(theme.surface.color)
                if let still { OpenedImage(data: still) }
                Image(systemName: "play.circle.fill")
                    .font(Typeface.display)
                    .foregroundStyle(theme.surface.color.opacity(0.9))
                    .shadow(radius: 2)
            }
            .frame(width: 220, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(alignment: .bottomTrailing) {
                if case .video(let seconds?) = message.kind {
                    Text(Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond)))
                        .font(Typeface.micro)
                        .padding(.horizontal, Space.s2)
                        .background(Capsule().fill(theme.surface.color.opacity(0.85)))
                        .padding(Space.s2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message.isOwn ? "Your video" : "Video from \(MessagesUsername.display(message.sender))")
        .task(id: "\(message.id)|\(message.state == .sent)") {
            guard message.state == .sent else { return }
            still = await model.photo(message, thumbnail: true)
        }
    }
}

/// Plays a video opened on this device. Its file is removed as soon as the player closes.
struct VideoViewer: View {
    let message: ChatMessage
    let model: ChatModel
    let onClose: () -> Void
    @State private var file: URL?
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ZStack {
                theme.bg.color.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                } else if failed {
                    MessagesStateView(systemImage: "video", title: "This video didn't open", detail: "Check your connection and try again.")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(message.isOwn ? "Your video" : MessagesUsername.display(message.sender))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
        }
        .tint(theme.accent.color)
        .task {
            guard let url = await model.playableVideo(message) else { failed = true; return }
            file = url
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }
}

#if os(iOS)
/// What the camera gave back.
enum CameraResult {
    case photo(Data)
    /// A file already moved into Messages' temporary folder.
    case video(URL)
}

/// The system camera, for a photo or a short video to send. Nothing is saved to the photo library.
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (CameraResult?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoMaximumDuration = VideoPrep.longest
        picker.videoQuality = .typeMedium
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (CameraResult?) -> Void
        init(onDone: @escaping (CameraResult?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movie = info[.mediaURL] as? URL {
                let copy = VideoFiles.folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(movie.pathExtension)
                if (try? FileManager.default.moveItem(at: movie, to: copy)) != nil {
                    onDone(.video(copy))
                } else {
                    onDone(nil)
                }
            } else if let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.95) {
                onDone(.photo(data))
            } else {
                onDone(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}
#endif
