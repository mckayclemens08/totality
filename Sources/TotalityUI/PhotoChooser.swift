import SwiftUI
import TotalityCore

private struct PhotoChooserKey: EnvironmentKey {
    static let defaultValue: (any PhotoChoosing)? = nil
}

extension EnvironmentValues {
    /// Photos' side of the shared chooser, set once by the app. Nil where Photos isn't running, and then
    /// the chooser goes straight to the iPhone's own picker.
    public var photoChooser: (any PhotoChoosing)? {
        get { self[PhotoChooserKey.self] }
        set { self[PhotoChooserKey.self] = newValue }
    }
}

/// Which kinds of media a chooser offers.
public enum ChooserKinds: Sendable {
    case photos, videos, photosAndVideos

    func allows(isVideo: Bool) -> Bool {
        switch self {
        case .photos: return !isVideo
        case .videos: return isVideo
        case .photosAndVideos: return true
        }
    }
}

extension View {
    /// The one place every module picks photos and videos. It shows the Photos library first, with
    /// "From iPhone" inside it, and hands back what was chosen, opened on this device. Where Photos can't
    /// open, it goes straight to the iPhone's picker.
    public func photoChooser(
        isPresented: Binding<Bool>,
        kinds: ChooserKinds = .photos,
        limit: Int = 1,
        onChoose: @escaping @MainActor ([ChosenMedia]) async -> Void
    ) -> some View {
        modifier(PhotoChooserModifier(isPresented: isPresented, kinds: kinds, limit: max(1, limit), onChoose: onChoose))
    }
}

#if os(iOS)
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

private struct PhotoChooserModifier: ViewModifier {
    @Binding var isPresented: Bool
    let kinds: ChooserKinds
    let limit: Int
    let onChoose: @MainActor ([ChosenMedia]) async -> Void
    @Environment(\.photoChooser) private var chooser
    @State private var direct = false
    @State private var directItems: [PhotosPickerItem] = []

    private var library: (any PhotoChoosing)? {
        guard let chooser, chooser.unavailableReason == nil else { return nil }
        return chooser
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, now in
                // Without the Photos library there's nothing to show first, so the iPhone's picker opens.
                if now, library == nil {
                    isPresented = false
                    direct = true
                }
            }
            .sheet(isPresented: $isPresented) {
                if let library {
                    PhotoChooserSheet(library: library, kinds: kinds, limit: limit) { media in
                        isPresented = false
                        await onChoose(media)
                    } onCancel: { isPresented = false }
                }
            }
            .photosPicker(
                isPresented: $direct, selection: $directItems, maxSelectionCount: limit,
                matching: ChooserLoading.filter(kinds), preferredItemEncoding: .compatible
            )
            .onChange(of: directItems) { _, items in
                guard !items.isEmpty else { return }
                directItems = []
                Task { await onChoose(await ChooserLoading.load(items)) }
            }
    }
}

/// Opening what the iPhone's picker hands over.
enum ChooserLoading {
    static func filter(_ kinds: ChooserKinds) -> PHPickerFilter {
        switch kinds {
        case .photos: return .images
        case .videos: return .videos
        case .photosAndVideos: return .any(of: [.images, .videos])
        }
    }

    static func load(_ items: [PhotosPickerItem]) async -> [ChosenMedia] {
        var made: [ChosenMedia] = []
        for item in items {
            let types = item.supportedContentTypes
            if types.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: ChosenMovie.self) { made.append(.video(movie.url)) }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                made.append(.photo(data, type: sniff(data) ?? types.first?.identifier))
            }
        }
        return made
    }

    /// The file's own type, read from its bytes.
    static func sniff(_ data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
    }
}

/// A video the iPhone's picker copied out for Totality, copied again because the picker's copy goes
/// away. It's protected until first unlock, and the caller removes it.
struct ChosenMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: copy.path)
            return ChosenMovie(url: copy)
        }
    }
}

/// The Photos library as a grid, with "From iPhone" at the top.
struct PhotoChooserSheet: View {
    let library: any PhotoChoosing
    let kinds: ChooserKinds
    let limit: Int
    let onChoose: @MainActor ([ChosenMedia]) async -> Void
    let onCancel: () -> Void

    @State private var selected: [UUID] = []
    @State private var fromIPhone = false
    @State private var iPhoneItems: [PhotosPickerItem] = []
    @State private var saveCopies = false
    @State private var working = false
    @State private var problem: String?

    private var shown: [ChoosablePhoto] { library.choices.filter { kinds.allows(isVideo: $0.isVideo) } }
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Space.s2)]

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Button { fromIPhone = true } label: {
                        Label("From iPhone", systemImage: "iphone")
                            .font(Typeface.callout)
                            .foregroundStyle(theme.accent.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.s3)
                            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    .buttonStyle(SoftPress())
                    .disabled(working)
                    Toggle("Also keep copies in Photos", isOn: $saveCopies)
                        .font(Typeface.callout)
                        .tint(theme.accent.color)
                    Text(saveCopies
                         ? "Photos you pick from the iPhone are saved, sealed, in your Photos library."
                         : "Photos you pick from the iPhone are used once and not saved in Totality.")
                        .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    if shown.isEmpty {
                        Text(kinds == .videos ? "No videos in your Photos yet. Choose From iPhone to pick one."
                             : "Nothing in your Photos yet. Choose From iPhone to pick one.")
                            .font(Typeface.body).foregroundStyle(theme.textSecondary.color)
                            .frame(maxWidth: .infinity).padding(.vertical, Space.s6)
                    } else {
                        Text("Your Photos").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        LazyVGrid(columns: columns, spacing: Space.s2) {
                            ForEach(shown) { photo in
                                ChooserCell(library: library, photo: photo, order: selected.firstIndex(of: photo.id).map { $0 + 1 }, showsNumber: limit > 1) {
                                    tap(photo)
                                }
                            }
                        }
                    }
                    if let problem {
                        Text(problem).font(Typeface.caption).foregroundStyle(theme.danger.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(kinds == .videos ? "Choose a video" : "Choose photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                if limit > 1 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.isEmpty ? "Done" : "Add \(selected.count)") { Task { await finish(selected) } }
                            .disabled(selected.isEmpty || working)
                    }
                }
            }
            .overlay { if working { ProgressView().padding(Space.s5).neumorphic(.raised, in: Circle()) } }
            .task { await library.refreshChoices() }
        }
        .photosPicker(
            isPresented: $fromIPhone, selection: $iPhoneItems, maxSelectionCount: limit,
            matching: ChooserLoading.filter(kinds), preferredItemEncoding: .compatible
        )
        .onChange(of: iPhoneItems) { _, items in
            guard !items.isEmpty else { return }
            iPhoneItems = []
            Task { await fromPhone(items) }
        }
    }

    private func tap(_ photo: ChoosablePhoto) {
        guard !working else { return }
        if limit == 1 {
            Task { await finish([photo.id]) }
        } else if let at = selected.firstIndex(of: photo.id) {
            selected.remove(at: at)
        } else if selected.count < limit {
            selected.append(photo.id)
        }
    }

    /// Opens each chosen photo on this device, in the order they were tapped.
    private func finish(_ ids: [UUID]) async {
        working = true
        problem = nil
        var media: [ChosenMedia] = []
        var failed = 0
        for id in ids {
            guard let photo = shown.first(where: { $0.id == id }) else { continue }
            do {
                if photo.isVideo {
                    media.append(.video(try await library.video(id)))
                } else {
                    let data = try await library.photo(id)
                    media.append(.photo(data, type: ChooserLoading.sniff(data)))
                }
            } catch {
                failed += 1
            }
        }
        working = false
        if media.isEmpty {
            problem = failed == 1 ? "That one couldn't be opened. Try another." : "Those couldn't be opened. Try others."
            selected = []
            return
        }
        await onChoose(media)
    }

    private func fromPhone(_ items: [PhotosPickerItem]) async {
        working = true
        let media = await ChooserLoading.load(items)
        working = false
        guard !media.isEmpty else {
            problem = "That couldn't be opened. Try another."
            return
        }
        if saveCopies { await library.keep(media) }
        await onChoose(media)
    }
}

/// One thumbnail. Selected is a raised, accent-outlined tile with its tap order, never a pressed-in one.
private struct ChooserCell: View {
    let library: any PhotoChoosing
    let photo: ChoosablePhoto
    let order: Int?
    let showsNumber: Bool
    let action: () -> Void
    @State private var image: CGImage?

    var body: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(image, scale: 1, label: Text(photo.isVideo ? "Video" : "Photo")).resizable().scaledToFill()
                    } else {
                        theme.surface.color
                    }
                }
                .clipShape(shape)
                .overlay(alignment: .bottomLeading) {
                    if photo.isVideo {
                        Image(systemName: "video.fill").font(Typeface.micro).foregroundStyle(.white).shadow(radius: 2).padding(Space.s1)
                    }
                }
                .overlay(shape.stroke(theme.accent.color, lineWidth: order == nil ? 0 : Metric.selectionOutline))
                .overlay(alignment: .topTrailing) {
                    if let order, showsNumber {
                        Text("\(order)").font(Typeface.micro).foregroundStyle(theme.accentOn.color)
                            .frame(width: Space.s5, height: Space.s5).background(theme.accent.color, in: Circle()).padding(Space.s1)
                    }
                }
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(photo.isVideo ? "Video" : "Photo")
        .accessibilityAddTraits(order == nil ? [] : .isSelected)
        .task { image = await library.thumbnail(of: photo.id) }
    }
}
#else
private struct PhotoChooserModifier: ViewModifier {
    @Binding var isPresented: Bool
    let kinds: ChooserKinds
    let limit: Int
    let onChoose: @MainActor ([ChosenMedia]) async -> Void
    func body(content: Content) -> some View { content }
}
#endif
