import PhotosUI
import SwiftUI
import TotalityCore
import TotalityUI

/// The library: every photo, newest first, by month. Add opens Apple's picker, which asks for no access
/// to the photo library. Only what the person picks is read.
public struct PhotosHomeView: View {
    @Bindable private var model: PhotosModel
    private let onClose: (() -> Void)?
    private let onOpenAccount: (() -> Void)?
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: Viewing?
    @State private var tab = Tab.library
    @State private var path: [PhotosModel.Scope] = []
    @State private var showingSync = false
    @State private var showingGoogle = false
    @State private var showingPicker = false

    /// The pills under the title (redesign, 2026-11-17). Videos and Favourites show their photos here.
    enum Tab: Hashable, CaseIterable {
        case library, albums, videos, favourites

        var title: String {
            switch self {
            case .library: "Library"
            case .albums: "Albums"
            case .videos: "Videos"
            case .favourites: "Favourites"
            }
        }

        var scope: PhotosModel.Scope? {
            switch self {
            case .library: .library
            case .albums: nil
            case .videos: .videos
            case .favourites: .favourites
            }
        }
    }

    /// The photo open full screen, and which photos the viewer moves through.
    struct Viewing: Equatable {
        let scope: PhotosModel.Scope
        let start: UUID
    }

    /// `onOpenAccount` shows the account, where signing in and the recovery key live.
    public init(model: PhotosModel, onClose: (() -> Void)? = nil, onOpenAccount: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        self.onOpenAccount = onOpenAccount
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg.color)
                .edgeSwipeBack(onClose)
                .overlay(alignment: .bottomTrailing) {
                    if model.phase == .ready && !isLibraryEmpty {
                        addButton
                    }
                }
                #if os(iOS)
                // Photos draws its own header (redesign, 2026-11-17).
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .navigationDestination(for: PhotosModel.Scope.self) { scope in
                    ScopeScreen(model: model, scope: scope) { open($0, in: scope) } onAlbumDeleted: { path.removeAll() }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #else
                .navigationTitle("Photos")
                #endif
        }
        .tint(theme.accent.color)
        .overlay {
            if let viewing {
                PhotoViewer(model: model, scope: viewing.scope, start: viewing.start) {
                    withMotion(Motion.snappy) { self.viewing = nil }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: picked) {
            let chosen = picked
            picked = []
            guard !chosen.isEmpty else { return }
            Task { await model.add(picks: chosen.map(PickedMedia.pick)) }
        }
        .alert("Photos", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .photosPicker(isPresented: $showingPicker, selection: $picked, matching: .any(of: [.images, .videos, .livePhotos]), preferredItemEncoding: .current, photoLibrary: .shared())
        .task { await model.load() }
        .sheet(isPresented: $showingGoogle) { GoogleImportSheet(model: model) }
        #if os(iOS)
        .sheet(isPresented: $showingSync) { SyncSheet(model: model) }
        #endif
        .onChange(of: model.requestedItem, initial: true) { openRequested() }
        .onChange(of: model.phase) { openRequested() }
    }

    /// A photo picked on the home tile opens in the viewer, over the library.
    private func openRequested() {
        guard model.phase == .ready, model.requestedItem != nil else { return }
        guard let id = model.takeRequest() else { return }
        tab = .library
        path.removeAll()
        viewing = Viewing(scope: .library, start: id)
    }

    private func open(_ item: PhotoItem, in scope: PhotosModel.Scope) {
        withMotion(Motion.snappy) { viewing = Viewing(scope: scope, start: item.id) }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    private var isLibraryEmpty: Bool { model.items(in: .library).isEmpty }

    /// Home on the left, Google Photos and Sync on the right, the big title, and the pills.
    private var header: some View {
        let ready = model.phase == .ready
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                if let onClose {
                    HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
                }
                Spacer(minLength: 0)
                AskTotalityButton(context: AIAskContext(id: "photos.home", module: .photos, title: "Photos"))
                if ready {
                    if model.canImportFromGoogle {
                        HeaderButton("Add from Google Photos", systemImage: "square.and.arrow.down.on.square.fill") { showingGoogle = true }
                    }
                    #if os(iOS)
                    if model.canSync {
                        HeaderButton("Sync this iPhone", systemImage: model.isSyncing ? "hourglass" : "arrow.triangle.2.circlepath") {
                            showingSync = true
                        }
                    }
                    #endif
                }
            }
            .frame(minHeight: Metric.headerButton)
            ScreenTitle("Photos")
            if ready {
                // Scrolls sideways rather than squashing the pills.
                FilterPills(Tab.allCases, selection: $tab) { $0.title }
                    .padding(.horizontal, -Space.s2)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .background(Theme.current.bg.color)
    }

    /// The accent + opens Apple's picker; while photos are adding it shows that instead.
    @ViewBuilder private var addButton: some View {
        if model.isAdding {
            ProgressView()
                .accessibilityLabel("Adding photos")
                .frame(width: Metric.addButton, height: Metric.addButton)
                .neumorphic(.raised, in: Circle())
                .padding(Space.s4)
        } else {
            AddButton("Add photos") { showingPicker = true }
                .padding(Space.s4)
        }
    }

    private var fixButton: (label: String, action: () -> Void)? {
        switch model.fix {
        case .openAccount:
            guard let onOpenAccount else { return nil }
            return ("Open your account", onOpenAccount)
        case .tryAgain:
            return ("Try again", { Task { await model.tryAgain() } })
        case nil:
            return nil
        }
    }

    private func addButton(label: String) -> some View {
        let isAdding = model.isAdding
        return PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos, .livePhotos]), preferredItemEncoding: .current, photoLibrary: .shared()) {
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
            VStack(spacing: Space.s5) {
                PhotosMessage(systemImage: model.fix == .tryAgain ? "exclamationmark.triangle" : "lock.slash", title: title, detail: detail)
                if let fix = fixButton {
                    Button(fix.label, action: fix.action)
                        .font(Typeface.callout)
                        .padding(.horizontal, Space.s5)
                        .padding(.vertical, Space.s3)
                        .neumorphic(.raised, in: Capsule())
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.current.accent.color)
                }
            }
        case .ready where tab == .albums:
            AlbumsScreen(model: model) { path.append($0) }
        case .ready where tab == .videos || tab == .favourites:
            let scope = tab.scope ?? .library
            if model.items(in: scope).isEmpty {
                PhotosMessage(
                    systemImage: tab == .videos ? "video" : "heart",
                    title: tab == .videos ? "No videos yet" : "No favourites yet",
                    detail: tab == .videos ? "Videos you add show up here." : "Tap the heart on a photo to keep it here."
                )
            } else {
                PhotoGrid(model: model, scope: scope) { open($0, in: scope) } footer: { EmptyView() }
            }
        case .ready where model.items(in: .library).isEmpty:
            VStack(spacing: Space.s5) {
                PhotosMessage(
                    systemImage: "photo.on.rectangle",
                    title: "No photos yet",
                    detail: "Add photos and videos from this device. They're sealed here before they upload, so only your devices can see them."
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
            PhotoGrid(model: model, scope: .library) { open($0, in: .library) } footer: { LibraryFooter(model: model) }
        }
    }
}

/// Photos in months, newest first. Pinch to see more or fewer in a row.
struct PhotoGrid<Footer: View>: View {
    let model: PhotosModel
    let scope: PhotosModel.Scope
    let onOpen: (PhotoItem) -> Void
    @ViewBuilder let footer: () -> Footer
    @State private var pinch: CGFloat = 1

    var body: some View {
        let theme = Theme.current
        let gap = Space.s1
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: model.columns)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s3, pinnedViews: [.sectionHeaders]) {
                ForEach(model.months(in: scope)) { month in
                    Section {
                        LazyVGrid(columns: columns, spacing: gap) {
                            ForEach(month.items) { item in
                                Button { onOpen(item) } label: {
                                    PhotoCell(model: model, item: item, showsDaysLeft: scope == .recentlyDeleted)
                                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Space.s4)
                    } header: {
                        Text(month.title)
                            .font(Typeface.callout.weight(.semibold))
                            .foregroundStyle(theme.textSecondary.color)
                            .padding(.horizontal, Space.s4)
                            .padding(.vertical, Space.s2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.bg.color.opacity(0.94))
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                footer()
            }
            // Room for the + button under the last row.
            .padding(.bottom, Metric.addButton + Space.s5)
        }
        .scaleEffect(pinch, anchor: .center)
        .gesture(
            MagnifyGesture()
                .onChanged { pinch = min(max($0.magnification, 0.85), 1.15) }
                .onEnded { value in
                    withMotion(Motion.snappy) {
                        pinch = 1
                        if value.magnification > 1.15 { model.change(columnsBy: -1) }
                        if value.magnification < 0.85 { model.change(columnsBy: 1) }
                    }
                }
        )
        .pullsToRefresh(with: model.refresher)
        .accessibilityAction(named: "Bigger photos") { model.change(columnsBy: -1) }
        .accessibilityAction(named: "Smaller photos") { model.change(columnsBy: 1) }
    }
}

/// The bottom of the library: what's waiting, what can't open, the space used, and what the server sees.
struct LibraryFooter: View {
    let model: PhotosModel

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s1) {
            if let waiting = model.waitingLine {
                Text(waiting).foregroundStyle(model.isFull ? theme.danger.color : theme.textSecondary.color)
            }
            if model.unreadable > 0 {
                Text((model.unreadable == 1
                    ? "One photo can't be opened with this device's key."
                    : "\(model.unreadable) photos can't be opened with this device's key.")
                    + " Check in your account that this device has joined your recovery key.")
                    .foregroundStyle(theme.textSecondary.color)
            }
            if let sync = model.syncLine {
                Text(sync).foregroundStyle(model.syncReport?.full == true ? theme.danger.color : theme.textSecondary.color)
            }
            if let usage = model.usageLine {
                Text(usage).foregroundStyle(theme.textSecondary.color)
            }
            Text("End-to-end encrypted. The server sees how many photos and albums you have, their sizes, and when they were added.")
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
/// Square in a grid, or whatever frame it's given on the home tile.
private struct CellShape: ViewModifier {
    let fills: Bool

    func body(content: Content) -> some View {
        if fills {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.aspectRatio(1, contentMode: .fit)
        }
    }
}

struct PhotoCell: View {
    let model: PhotosModel
    let item: PhotoItem
    var showsDaysLeft = false
    /// Fills whatever frame it's given, as on the home tile, rather than keeping square.
    var fills = false
    @State private var image: CGImage?

    var body: some View {
        let theme = Theme.current
        Color.clear
            .modifier(CellShape(fills: fills))
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
            .overlay(alignment: .bottomLeading) {
                if item.details.favourite {
                    Image(systemName: "heart.fill")
                        .font(Typeface.micro)
                        .foregroundStyle(theme.accent.color)
                        .padding(Space.s1)
                        .background(theme.surface.color.opacity(0.85), in: Circle())
                        .padding(Space.s1)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottom) {
                if showsDaysLeft, let days = PhotosModel.daysLeft(item) {
                    Text(days == 1 ? "1 day" : "\(days) days")
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textPrimary.color)
                        .padding(.horizontal, Space.s2)
                        .background(theme.surface.color.opacity(0.85), in: Capsule())
                        .padding(Space.s1)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                if item.details.isLive {
                    Image(systemName: "livephoto")
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textPrimary.color)
                        .padding(Space.s1)
                        .background(theme.surface.color.opacity(0.85), in: Circle())
                        .padding(Space.s1)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.details.isVideo, let duration = item.details.duration {
                    Text(PhotosModel.durationText(duration))
                        .font(Typeface.micro)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                        .padding(.horizontal, Space.s2)
                        .background(theme.surface.color.opacity(0.85), in: Capsule())
                        .padding(Space.s1)
                        .accessibilityHidden(true)
                }
            }
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
        Self.label(of: item, showsDaysLeft: showsDaysLeft)
    }

    static func label(of item: PhotoItem, showsDaysLeft: Bool = false) -> String {
        let kind = item.details.isVideo ? "Video" : item.details.isLive ? "Live Photo" : "Photo"
        var parts = ["\(kind) from \(item.date.formatted(date: .long, time: .shortened))"]
        if item.details.isVideo, let duration = item.details.duration { parts.append(PhotosModel.durationText(duration)) }
        if item.details.favourite { parts.append("favourite") }
        if let caption = item.details.caption { parts.append(caption) }
        if item.isWaiting { parts.append("waiting to upload") }
        if showsDaysLeft, let days = PhotosModel.daysLeft(item) { parts.append(days == 1 ? "deleted for good in 1 day" : "deleted for good in \(days) days") }
        return parts.joined(separator: ", ")
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
