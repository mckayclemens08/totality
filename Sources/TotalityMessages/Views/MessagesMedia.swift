import SwiftUI
import TotalityUI
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

#if os(iOS)
/// The system camera, for a photo to send. Nothing is saved to the photo library.
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (Data?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (Data?) -> Void
        init(onDone: @escaping (Data?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.95))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}
#endif
