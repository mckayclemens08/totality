import SwiftUI
import TotalityCore
import TotalityUI

/// Favourites, Recently Deleted, and the albums the person made. Album names are sealed like the rest.
struct AlbumsScreen: View {
    let model: PhotosModel
    let onOpen: (PhotosModel.Scope) -> Void
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let theme = Theme.current
        let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.s4)]
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.s5) {
                AlbumCard(model: model, title: "Favourites", systemImage: "heart", items: model.items(in: .favourites)) { onOpen(.favourites) }
                AlbumCard(model: model, title: "Videos", systemImage: "video", items: model.items(in: .videos)) { onOpen(.videos) }
                ForEach(model.albums) { album in
                    AlbumCard(model: model, title: album.name, systemImage: "rectangle.stack", items: model.items(in: .album(album.id))) {
                        onOpen(.album(album.id))
                    }
                }
                Button {
                    newName = ""
                    naming = true
                } label: {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Image(systemName: "plus")
                            .font(Typeface.title)
                            .foregroundStyle(theme.accent.color)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
                        Text("New Album").font(Typeface.callout).foregroundStyle(theme.textPrimary.color)
                        Text(" ").font(Typeface.caption)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(Space.s4)

            Button { onOpen(.recentlyDeleted) } label: {
                HStack {
                    Label("Recently Deleted", systemImage: "trash")
                    Spacer()
                    Text("\(model.items(in: .recentlyDeleted).count)").foregroundStyle(theme.textSecondary.color)
                    Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary.color)
                }
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .padding(Space.s4)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s6)

            Text("Album names, captions, and favourites are sealed with your photos. The server can't read them.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textTertiary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.s5)
                .padding(.bottom, Space.s5)
        }
        .refreshable { await model.load() }
        .alert("New Album", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Make") {
                let name = newName
                Task { await model.makeAlbum(named: name) }
            }
            .disabled(PhotoAlbum.tidy(newName) == nil)
        } message: {
            Text("Its name is sealed, so only your devices can read it.")
        }
    }
}

/// An album as a square of its newest photo, with its name and how many it holds.
struct AlbumCard: View {
    let model: PhotosModel
    let title: String
    let systemImage: String
    let items: [PhotoItem]
    let onOpen: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Group {
                    if let cover = items.first {
                        PhotoCell(model: model, item: cover)
                    } else {
                        Image(systemName: systemImage)
                            .font(Typeface.title)
                            .foregroundStyle(theme.textTertiary.color)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(theme.surfaceSunken.color)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
                Text(title).font(Typeface.callout).foregroundStyle(theme.textPrimary.color).lineLimit(1)
                Text(items.count == 1 ? "1 photo" : "\(items.count) photos").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(items.count == 1 ? "1 photo" : "\(items.count) photos")")
        .accessibilityAddTraits(.isButton)
    }
}

/// One album, Favourites, or Recently Deleted, as a grid.
struct ScopeScreen: View {
    let model: PhotosModel
    let scope: PhotosModel.Scope
    let onOpen: (PhotoItem) -> Void
    let onAlbumDeleted: () -> Void
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var confirmingEmpty = false

    var body: some View {
        let theme = Theme.current
        Group {
            if model.items(in: scope).isEmpty {
                PhotosMessage(systemImage: emptyImage, title: emptyTitle, detail: emptyDetail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PhotoGrid(model: model, scope: scope, onOpen: onOpen) {
                    if scope == .recentlyDeleted {
                        Text("Photos here are deleted for good after \(PhotoLibrary.trashDays) days, from every device.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textTertiary.color)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(Space.s5)
                    }
                }
            }
        }
        .background(theme.bg.color)
        .navigationTitle(model.title(of: scope))
        .toolbar {
            if case .album(let id) = scope, let album = model.album(id) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Rename", systemImage: "pencil") {
                            newName = album.name
                            renaming = true
                        }
                        Button("Delete Album", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    } label: {
                        Label("Album", systemImage: "ellipsis.circle")
                    }
                }
            }
            if scope == .recentlyDeleted, !model.items(in: scope).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete All", role: .destructive) { confirmingEmpty = true }
                }
            }
        }
        .alert("Rename Album", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard case .album(let id) = scope, let album = model.album(id) else { return }
                let name = newName
                Task { await model.rename(album, to: name) }
            }
            .disabled(PhotoAlbum.tidy(newName) == nil)
        }
        .confirmationDialog("Delete this album?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                guard case .album(let id) = scope, let album = model.album(id) else { return }
                Task {
                    await model.deleteAlbum(album)
                    if model.album(id) == nil { onAlbumDeleted() }
                }
            }
        } message: {
            Text("The photos stay in your library.")
        }
        .confirmationDialog("Delete these photos for good?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Delete for Good", role: .destructive) { Task { await model.emptyRecentlyDeleted() } }
        } message: {
            Text("They're removed from every device and the server. This can't be undone.")
        }
    }

    private var emptyImage: String {
        switch scope {
        case .favourites: "heart"
        case .videos: "video"
        case .recentlyDeleted: "trash"
        default: "rectangle.stack"
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .favourites: "No favourites yet"
        case .videos: "No videos yet"
        case .recentlyDeleted: "Nothing recently deleted"
        case .album(let id): model.album(id) == nil ? "This album is gone" : "This album is empty"
        case .library: "No photos yet"
        }
    }

    private var emptyDetail: String {
        switch scope {
        case .favourites: "Tap the heart on a photo to keep it here."
        case .videos: "Add a video with Add. Videos up to 10 minutes are sealed here before they upload."
        case .recentlyDeleted: "Photos you delete wait here for \(PhotoLibrary.trashDays) days, so you can bring them back."
        case .album(let id): model.album(id) == nil
            ? "It was deleted, maybe on another device. Its photos are still in your library."
            : "Open a photo and choose Add to Album to put it here."
        case .library: "Add photos from this device."
        }
    }
}
