import PhotosUI
import SwiftUI
import TotalityCore
import TotalityUI

/// The library: every photo, newest first, by month. Add opens Apple's picker, which asks for no access
/// to the photo library. Only what the person picks is read.
public struct PhotosHomeView: View {
    @Bindable private var model: PhotosModel
    private let onClose: (() -> Void)?
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: UUID?
    @State private var pinch: CGFloat = 1

    public init(model: PhotosModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg.color)
                .edgeSwipeBack(onClose)
                .toolbar { toolbar }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #else
                .navigationTitle("Photos")
                #endif
        }
        .tint(theme.accent.color)
        .overlay {
            if let viewing {
                PhotoViewer(model: model, start: viewing) { withAnimation(Motion.quick) { self.viewing = nil } }
                    .transition(.opacity)
            }
        }
        .onChange(of: picked) {
            let chosen = picked
            picked = []
            guard !chosen.isEmpty else { return }
            Task { await model.add(chosen.map { item in { try await item.loadTransferable(type: Data.self) } }) }
        }
        .alert("Photos", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .task { await model.load() }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                Button("Home", systemImage: "circle.hexagongrid", action: onClose)
            }
        }
        #if os(iOS)
        ToolbarItem(placement: .principal) {
            Text("Photos").font(Typeface.headline).foregroundStyle(Theme.current.textPrimary.color)
        }
        #endif
        if model.phase == .ready {
            ToolbarItem(placement: .primaryAction) { addButton(label: "Add") }
        }
    }

    private func addButton(label: String) -> some View {
        let isAdding = model.isAdding
        return PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
            if isAdding {
                ProgressView().accessibilityLabel("Adding photos")
            } else {
                Label(label, systemImage: "plus")
            }
        }
        .disabled(isAdding)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            PhotosMessage(systemImage: nil, title: "Opening your photos", detail: nil)
        case .unavailable(let title, let detail):
            PhotosMessage(systemImage: "lock.slash", title: title, detail: detail)
        case .ready where model.items.isEmpty:
            VStack(spacing: Space.s5) {
                PhotosMessage(
                    systemImage: "photo.on.rectangle",
                    title: "No photos yet",
                    detail: "Add photos from this device. They're sealed here before they upload, so only your devices can see them."
                )
                .frame(maxHeight: nil)
                addButton(label: "Add photos")
                    .font(Typeface.callout)
                    .padding(.horizontal, Space.s5)
                    .padding(.vertical, Space.s3)
                    .neumorphic(.raised, in: Capsule())
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.current.accent.color)
            }
        case .ready:
            library
        }
    }

    private var library: some View {
        let theme = Theme.current
        let gap: CGFloat = 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: model.columns)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s3, pinnedViews: [.sectionHeaders]) {
                ForEach(model.months) { month in
                    Section {
                        LazyVGrid(columns: columns, spacing: gap) {
                            ForEach(month.items) { item in
                                Button {
                                    withAnimation(Motion.quick) { viewing = item.id }
                                } label: {
                                    PhotoCell(model: model, item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text(month.title)
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                            .padding(.horizontal, Space.s4)
                            .padding(.vertical, Space.s2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.bg.color.opacity(0.94))
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                footer
            }
        }
        .scaleEffect(pinch, anchor: .center)
        .gesture(
            MagnifyGesture()
                .onChanged { pinch = min(max($0.magnification, 0.85), 1.15) }
                .onEnded { value in
                    withAnimation(Motion.quick) {
                        pinch = 1
                        if value.magnification > 1.15 { model.change(columnsBy: -1) }
                        if value.magnification < 0.85 { model.change(columnsBy: 1) }
                    }
                }
        )
        .refreshable { await model.load() }
        .accessibilityAction(named: "Bigger photos") { model.change(columnsBy: -1) }
        .accessibilityAction(named: "Smaller photos") { model.change(columnsBy: 1) }
    }

    private var footer: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s1) {
            if let waiting = model.waitingLine {
                Text(waiting).foregroundStyle(model.isFull ? theme.danger.color : theme.textSecondary.color)
            }
            if model.unreadable > 0 {
                Text(model.unreadable == 1
                    ? "One photo can't be opened with this device's key."
                    : "\(model.unreadable) photos can't be opened with this device's key.")
                    .foregroundStyle(theme.textSecondary.color)
            }
            if let usage = model.usageLine {
                Text(usage).foregroundStyle(theme.textSecondary.color)
            }
            Text("End-to-end encrypted. The server sees how many photos you have, their sizes, and when they were added.")
                .foregroundStyle(theme.textTertiary.color)
        }
        .font(Typeface.caption)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s5)
    }
}

/// One square in the grid, filled from the sealed thumbnail once it's opened.
struct PhotoCell: View {
    let model: PhotosModel
    let item: PhotoItem
    @State private var image: CGImage?

    var body: some View {
        let theme = Theme.current
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = image ?? model.cachedThumbnail(item) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    theme.surfaceSunken.color
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.isWaiting {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Typeface.micro)
                        .foregroundStyle(theme.accent.color, theme.surface.color)
                        .padding(Space.s1)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(label)
            .task(id: item.id) {
                if image == nil { image = await model.thumbnail(item) }
            }
    }

    private var label: String {
        let date = item.date.formatted(date: .long, time: .shortened)
        return item.isWaiting ? "Photo from \(date), waiting to upload" : "Photo from \(date)"
    }
}

/// A short message in the middle of the screen, for empty and error states.
struct PhotosMessage: View {
    let systemImage: String?
    let title: String
    let detail: String?

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Typeface.display)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
            }
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            if let detail {
                Text(detail)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(Space.s5)
    }
}
