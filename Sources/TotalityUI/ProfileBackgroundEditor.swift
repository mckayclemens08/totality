import SwiftUI
import TotalityCore

public struct ProfileBackgroundEditor: View {
    let store: any ProfileBackgroundStore
    let name: String
    let onChange: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key: String?
    @State private var saved: CGImage?
    @State private var draft: CGImage?
    @State private var checkingKey = true
    @State private var choosing = false
    @State private var removing = false
    @State private var working = false
    @State private var issue: String?
    @State private var position = CGPoint(x: 0.5, y: 0.5)
    @State private var zoom: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    public init(store: any ProfileBackgroundStore, key: String?, name: String, onChange: @escaping (String?) -> Void) {
        self.store = store
        self.name = name
        self.onChange = onChange
        _key = State(initialValue: key)
    }

    public var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack {
                    Text(draft == nil ? "Background" : "Position").font(Typeface.title)
                    Spacer()
                    HeaderButton("Close", systemImage: "xmark") { dismiss() }.disabled(working)
                }
                if let draft {
                    Text("Drag the picture, then zoom.").font(Typeface.callout)
                    GeometryReader { geometry in
                        preview(crop(draft, at: draggedPosition(in: geometry.size)), positioning: true)
                            .gesture(DragGesture()
                                .updating($drag) { value, offset, _ in offset = value.translation }
                                .onEnded { value in position = offsetPosition(by: value.translation, in: geometry.size) })
                    }
                    .aspectRatio(ProfileBackgroundPhoto.aspectRatio, contentMode: .fit)
                    Slider(value: $position.y, in: 0...1) { Text("Up and down") }
                    Slider(value: $zoom, in: 1...ProfileBackgroundPhoto.maximumZoom) { Text("Zoom") }
                    HStack {
                        HeaderPill("Cancel") { self.draft = nil }
                        HeaderPill("Save background", isProminent: true) {
                            Task {
                                working = true
                                let point = position
                                let scale = zoom
                                let jpeg = await Task.detached {
                                    ProfileBackgroundPhoto.prepare(draft, position: point, zoom: scale)
                                }.value
                                if let jpeg { await save(jpeg) }
                                else { issue = "That picture couldn’t be prepared. Try another." }
                                working = false
                            }
                        }
                    }
                } else {
                    Text("Public · Anyone signed in to Totality can see this, except people on either side of a block. The picture is stored unencrypted.")
                        .font(Typeface.caption)
                    preview(saved)
                        .aspectRatio(ProfileBackgroundPhoto.aspectRatio, contentMode: .fit)
                    HeaderPill("Choose from Photos", systemImage: "photo") { choosing = true }
                    if let saved {
                        HeaderPill("Reposition", systemImage: "crop") { begin(saved) }
                    }
                    if key != nil {
                        HeaderPill("Remove background", systemImage: "trash") { removing = true }
                    }
                }
                if working || checkingKey { ProgressView() }
                if let issue { Text(issue).font(Typeface.caption).foregroundStyle(theme.danger.color) }
            }
            .disabled(working || checkingKey)
            .padding(Space.s4)
        }
        .background(theme.bg.color.ignoresSafeArea())
        .foregroundStyle(theme.textPrimary.color)
        .interactiveDismissDisabled(working)
        .task {
            defer { checkingKey = false }
            do {
                let current = try await store.ownBackgroundKey()
                try Task.checkCancellation()
                key = current
            } catch {
                if !Task.isCancelled { issue = "The latest background couldn’t be checked." }
            }
        }
        .task(id: key) {
            saved = nil
            guard let key else { return }
            do {
                let data = try await store.backgroundPhoto(key)
                let decoded = await Task.detached { ProfileBackgroundPhoto.decode(data) }.value
                try Task.checkCancellation()
                saved = decoded
                if decoded == nil { issue = "The background didn’t load." }
            } catch {
                if !Task.isCancelled { issue = "The background didn’t load." }
            }
        }
        .photoChooser(isPresented: $choosing) { media in
            guard case .photo(let data, _)? = media.first,
                  let image = await Task.detached(operation: { ProfileBackgroundPhoto.decode(data) }).value
            else { issue = "Choose a photo up to 20 MB."; return }
            begin(image)
        }
        .confirmationDialog("Remove your background?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove background", role: .destructive) {
                Task {
                    working = true
                    await save(nil)
                    working = false
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Your profile goes back to the plain look. You can add a background again any time.")
        }
    }

    private func begin(_ image: CGImage) {
        position = CGPoint(x: 0.5, y: 0.5)
        zoom = 1
        issue = nil
        draft = image
    }

    private func save(_ jpeg: Data?) async {
        do {
            key = try await store.updateBackground(jpeg, replacing: key)
            onChange(key)
            draft = nil
            issue = nil
        } catch {
            do { key = try await store.ownBackgroundKey() }
            catch { /* Keep the last known key until the next attempt. */ }
            issue = "Your background couldn’t be updated. Try again."
        }
    }

    private func crop(_ image: CGImage, at point: CGPoint) -> CGImage? {
        image.cropping(to: ProfileBackgroundPhoto.cropRect(
            in: CGSize(width: image.width, height: image.height), position: point, zoom: zoom
        ).integral)
    }

    private func draggedPosition(in size: CGSize) -> CGPoint { offsetPosition(by: drag, in: size) }

    private func offsetPosition(by offset: CGSize, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(position.x - offset.width / max(size.width, 1), 0), 1),
                y: min(max(position.y - offset.height / max(size.height, 1), 0), 1))
    }

    private func preview(_ image: CGImage?, positioning: Bool = false) -> some View {
        Rectangle().fill(Theme.current.highlight.color)
            .overlay {
                if let image {
                    GeometryReader { geometry in
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                    ProfileBackgroundStyle.scrim.color
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(positioning ? "Name, bio, counts" : name)
                    .font(Typeface.title)
                    .foregroundStyle(image == nil ? Theme.current.textPrimary.color : ProfileBackgroundStyle.ink.color)
                    .padding(Space.s4)
            }
            .clipShape(.rect(cornerRadius: Radius.lg))
    }
}

/// Fixed photo-overlay colours have the same contrast in all six themes.
public enum ProfileBackgroundStyle {
    public static let ink = ColorToken(0xFFFFFF)
    public static let secondaryInk = ColorToken(0xFFFFFF, opacity: 0.88)
    public static let scrim = ColorToken(0x000000, opacity: 0.64)
    public static let glass = ColorToken(0x000000, opacity: 0.55)
}
