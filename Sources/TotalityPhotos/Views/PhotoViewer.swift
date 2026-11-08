import SwiftUI
import TotalityCore
import TotalityUI

/// One photo, full screen. Swipe or use the arrows to move between photos, pinch or double-tap to zoom,
/// and swipe down to close. The thumbnail shows at once, and the original replaces it once it's opened.
struct PhotoViewer: View {
    let model: PhotosModel
    let scope: PhotosModel.Scope
    let start: UUID
    let onClose: () -> Void
    @State private var current: UUID?
    /// The photos when the viewer opened, so one moved out of this scope doesn't jump the pages.
    @State private var shown: [UUID] = []
    @State private var showingInfo = false
    @State private var confirmingSave = false
    @State private var confirmingDelete = false
    @State private var isSaving = false

    private var items: [PhotoItem] {
        let byID = Dictionary(model.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return shown.compactMap { byID[$0] }
    }

    var body: some View {
        let theme = Theme.current
        let items = items
        ZStack {
            theme.bg.color.ignoresSafeArea()
            #if os(iOS)
            TabView(selection: $current) {
                ForEach(items) { item in
                    ZoomablePhoto(model: model, item: item, onClose: onClose).tag(Optional(item.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            #else
            if let item = items.first(where: { $0.id == current }) {
                ZoomablePhoto(model: model, item: item, onClose: onClose).id(item.id)
            }
            #endif
        }
        .overlay(alignment: .top) { bar(items) }
        .overlay(alignment: .bottom) { actions(items) }
        .onAppear {
            shown = model.items(in: scope).map(\.id)
            current = start
        }
        #if os(macOS)
        .onKeyPress(.leftArrow) { move(-1, in: items); return .handled }
        .onKeyPress(.rightArrow) { move(1, in: items); return .handled }
        #endif
        .onKeyPress(.escape) { onClose(); return .handled }
        .sheet(isPresented: $showingInfo) {
            if let item = items.first(where: { $0.id == current }) {
                PhotoInfoSheet(model: model, item: item)
            }
        }
        .confirmationDialog("Save to your Photos?", isPresented: $confirmingSave, titleVisibility: .visible) {
            Button("Save to Photos") { save() }
        } message: {
            Text("The copy in your device's Photos isn't sealed by Totality, and Photos may back it up to iCloud.")
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(scope == .recentlyDeleted ? "Delete for Good" : "Delete", role: .destructive) { delete() }
        } message: {
            Text(scope == .recentlyDeleted
                ? "It's removed from every device and the server. This can't be undone."
                : "It goes to Recently Deleted for \(PhotoLibrary.trashDays) days, on every device.")
        }
    }

    private var deleteTitle: String {
        scope == .recentlyDeleted ? "Delete this photo for good?" : "Delete this photo?"
    }

    private func bar(_ items: [PhotoItem]) -> some View {
        let theme = Theme.current
        let item = items.first { $0.id == current }
        return HStack(spacing: Space.s3) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(Typeface.body)
                    .frame(width: Space.s7, height: Space.s7)
                    .neumorphic(.subtle, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            Spacer(minLength: 0)
            if let item {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(item.date.formatted(date: .abbreviated, time: .omitted)).font(Typeface.callout)
                    Text(item.date.formatted(date: .omitted, time: .shortened)).font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .neumorphic(.subtle, in: Capsule())
            }
            #if os(macOS)
            Button { move(-1, in: items) } label: { Image(systemName: "chevron.left").frame(width: Space.s7, height: Space.s7) }
                .buttonStyle(.plain).neumorphic(.subtle, in: Circle()).accessibilityLabel("Previous photo")
            Button { move(1, in: items) } label: { Image(systemName: "chevron.right").frame(width: Space.s7, height: Space.s7) }
                .buttonStyle(.plain).neumorphic(.subtle, in: Circle()).accessibilityLabel("Next photo")
            #endif
        }
        .foregroundStyle(theme.textPrimary.color)
        .padding(Space.s4)
    }

    @ViewBuilder private func actions(_ items: [PhotoItem]) -> some View {
        let theme = Theme.current
        if let item = items.first(where: { $0.id == current }) {
            VStack(spacing: Space.s2) {
                if let caption = item.details.caption {
                    Text(caption)
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(3)
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s2)
                        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm))
                }
                HStack(spacing: Space.s5) {
                    if scope == .recentlyDeleted {
                        actionButton("Restore", systemImage: "arrow.uturn.backward") {
                            Task { await model.restore(item); closeIfGone() }
                        }
                        actionButton("Delete for Good", systemImage: "trash") { confirmingDelete = true }
                    } else {
                        actionButton(item.details.favourite ? "Unfavourite" : "Favourite",
                                     systemImage: item.details.favourite ? "heart.fill" : "heart",
                                     tint: item.details.favourite ? theme.accent.color : nil) {
                            Task { await model.toggleFavourite(item) }
                        }
                        actionButton("Info", systemImage: "info.circle") { showingInfo = true }
                        albumMenu(item)
                        if isSaving {
                            ProgressView().frame(width: Space.s7, height: Space.s7).accessibilityLabel("Saving to Photos")
                        } else {
                            actionButton("Save to Photos", systemImage: "square.and.arrow.down") { confirmingSave = true }
                        }
                        actionButton("Delete", systemImage: "trash") { confirmingDelete = true }
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)
                .neumorphic(.subtle, in: Capsule())
            }
            .padding(Space.s4)
        }
    }

    private func actionButton(_ label: String, systemImage: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        let theme = Theme.current
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.body)
                .foregroundStyle(tint ?? theme.textPrimary.color)
                .frame(width: Space.s7, height: Space.s7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func albumMenu(_ item: PhotoItem) -> some View {
        let theme = Theme.current
        return Menu {
            if model.albums.isEmpty {
                Text("Make an album in Albums first.")
            }
            ForEach(model.albums) { album in
                let isIn = item.details.albumIDs.contains(album.id)
                Button {
                    Task { await model.set(item, in: album, !isIn) }
                } label: {
                    if isIn { Label(album.name, systemImage: "checkmark") } else { Text(album.name) }
                }
            }
        } label: {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: Space.s7, height: Space.s7)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Add to Album")
    }

    private func delete() {
        guard let item = items.first(where: { $0.id == current }) else { return }
        Task {
            if scope == .recentlyDeleted {
                await model.deleteForGood(item)
            } else {
                await model.moveToRecentlyDeleted(item)
            }
            closeIfGone()
        }
    }

    /// Restored or deleted photos leave this scope. With none left, the viewer closes.
    private func closeIfGone() {
        let ids = Set(model.items(in: scope).map(\.id))
        let next = current.flatMap { ids.contains($0) ? $0 : neighbour(of: $0) }
        shown.removeAll { !ids.contains($0) }
        if shown.isEmpty { onClose() } else { current = next.flatMap { shown.contains($0) ? $0 : nil } ?? shown.first }
    }

    private func neighbour(of id: UUID) -> UUID? {
        guard let index = shown.firstIndex(of: id) else { return nil }
        if shown.indices.contains(index + 1) { return shown[index + 1] }
        return index > 0 ? shown[index - 1] : nil
    }

    private func save() {
        guard let item = items.first(where: { $0.id == current }) else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await PhotoSaver.save(try await model.original(item))
                model.notice = "Saved to your Photos."
            } catch PhotoSaver.Failure.notAllowed {
                model.notice = "Totality isn't allowed to add to your Photos. You can allow it in Settings, under Privacy, then Photos."
            } catch {
                model.notice = "The photo couldn't be saved. Try again in a moment."
            }
        }
    }

    private func move(_ step: Int, in items: [PhotoItem]) {
        guard let index = items.firstIndex(where: { $0.id == current }) else { return }
        let next = index + step
        guard items.indices.contains(next) else { return }
        current = items[next].id
    }
}

/// A photo that zooms. At normal size, a swipe down closes the viewer.
struct ZoomablePhoto: View {
    let model: PhotosModel
    let item: PhotoItem
    let onClose: () -> Void
    @State private var full: CGImage?
    @State private var thumbnail: CGImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let theme = Theme.current
        GeometryReader { geometry in
            ZStack {
                if let image = full ?? thumbnail ?? model.cachedThumbnail(item) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .accessibilityLabel("Photo from \(item.date.formatted(date: .long, time: .shortened))")
                } else {
                    ProgressView()
                }
                if failed {
                    Text("The full photo couldn't be opened. What you see is its thumbnail.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(Space.s3)
                        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(Space.s5)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(magnify)
            .simultaneousGesture(drag)
            .onTapGesture(count: 2) {
                withAnimation(Motion.quick) {
                    if scale > 1 { reset() } else { scale = 2.5; settledScale = 2.5 }
                }
            }
            .task(id: item.id) {
                thumbnail = await model.thumbnail(item)
                let side = Int(max(geometry.size.width, geometry.size.height) * displayScale * 1.5)
                do {
                    full = try await model.fullImage(item, side: max(side, 1_024))
                } catch is CancellationError {
                } catch {
                    failed = true
                }
            }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { scale = min(max(settledScale * $0.magnification, 1), 6) }
            .onEnded { _ in
                settledScale = scale
                if scale <= 1.01 { withAnimation(Motion.quick) { reset() } }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                } else if value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) {
                    offset = CGSize(width: 0, height: value.translation.height)
                }
            }
            .onEnded { value in
                if scale > 1 {
                    settledOffset = offset
                } else if value.translation.height > 120, abs(value.translation.height) > abs(value.translation.width) {
                    onClose()
                } else {
                    withAnimation(Motion.quick) { offset = .zero }
                }
            }
    }

    private func reset() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }
}
