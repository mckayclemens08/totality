import SwiftUI
import TotalityUI

/// One level of the library, or the top of it. Folders come first, then everything else.
struct ReaderFolderView: View {
    let folder: UUID?
    let model: ReaderModel
    @Binding var path: [ReaderRoute]
    let onClose: (() -> Void)?

    // Which way this device likes to look at things. These hold no content.
    @AppStorage("reader.sort") private var sort = ReaderSort.recent.rawValue
    @AppStorage("reader.grid") private var showsGrid = false

    @State private var importing = false
    @State private var importsToSpeechify = false
    @State private var namingFolder = false
    @State private var renaming: ReaderItem?
    @State private var name = ""
    @State private var moving: ReaderItem?
    @State private var deleting: ReaderItem?

    private var theme: Theme { .current }
    private var sortOrder: ReaderSort { ReaderSort(rawValue: sort) ?? .recent }
    private var current: ReaderItem? { folder.flatMap { id in model.library.folders.first { $0.id == id } } }
    private var title: String { current?.displayTitle ?? "Reader" }
    private var contents: (folders: [ReaderItem], items: [ReaderItem]) {
        model.library.contents(of: folder, sortedBy: sortOrder)
    }

    var body: some View {
        content
            .background(theme.bg.color)
            .navigationTitle(title)
            .toolbar { toolbar }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    let toSpeechify = importsToSpeechify
                    Task {
                        if toSpeechify {
                            await model.importSpeechify(urls)
                        } else {
                            await model.importFiles(urls, into: folder)
                        }
                    }
                } else if case .failure = result {
                    model.notice = "Those files couldn't be opened."
                }
            }
            .alert("New folder", isPresented: $namingFolder) {
                TextField("Name", text: $name)
                Button("Create") {
                    let title = cleanedName
                    Task { await model.newFolder(title, in: folder) }
                }
                .disabled(cleanedName.isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: isRenaming, presenting: renaming) { entry in
                TextField("Name", text: $name)
                Button("Save") {
                    let title = cleanedName
                    Task { await model.rename(entry, to: title) }
                }
                .disabled(cleanedName.isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: isDeleting, titleVisibility: .visible, presenting: deleting) { entry in
                Button("Delete", role: .destructive) {
                    Task { await model.delete(entry) }
                }
            } message: { _ in
                Text("Everything inside stays in Recently Deleted for 30 days.")
            }
            .sheet(item: $moving) { entry in
                ReaderMoveSheet(entry: entry, library: model.library) { destination in
                    Task { await model.move(entry, to: destination) }
                }
            }
    }

    private var cleanedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var deleteTitle: String {
        guard let deleting else { return "" }
        let count = insideCount(deleting)
        let inside = count == 1 ? "1 item" : "\(count) items"
        return "Delete \(deleting.displayTitle) and the \(inside) inside?"
    }

    private func insideCount(_ entry: ReaderItem) -> Int {
        model.library.descendants(of: entry.id).filter { $0.kind != .folder }.count
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                Button("Home", systemImage: "circle.hexagongrid", action: onClose)
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    Text("Recent").tag(ReaderSort.recent.rawValue)
                    Text("Name").tag(ReaderSort.name.rawValue)
                    Text("Type").tag(ReaderSort.type.rawValue)
                }
                Picker("View", selection: $showsGrid) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Grid", systemImage: "square.grid.2x2").tag(true)
                }
            } label: {
                Label("Sort and view", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New doc", systemImage: "square.and.pencil") { createDoc() }
                Button("New folder", systemImage: "folder.badge.plus") {
                    name = ""
                    namingFolder = true
                }
                Button("Import files", systemImage: "square.and.arrow.down") {
                    importsToSpeechify = false
                    importing = true
                }
                if folder == nil {
                    Button("Import into \(ReaderItem.speechifyCollection)", systemImage: "books.vertical") {
                        importsToSpeechify = true
                        importing = true
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private func createDoc() {
        Task {
            if let item = await model.newNote(in: folder) { path.append(.item(item)) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Opening your Reader")
                .font(Typeface.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ReaderMessage(
                systemImage: "exclamationmark.triangle",
                title: "Your Reader didn't open",
                detail: "This device's storage couldn't be read. Close the Reader and try again."
            )
        case .ready where folder == nil && model.isSearching:
            searchResults
        case .ready where folder != nil && current == nil:
            ReaderMessage(
                systemImage: "folder.badge.questionmark",
                title: "This folder is gone",
                detail: "It was deleted or moved. Anything that was inside is at the top of your Reader, or in Recently Deleted."
            )
        case .ready where isEmptyLibrary:
            ReaderMessage(
                systemImage: "book",
                title: "Nothing here yet",
                detail: model.isSynced
                    ? "Write a doc, or import a PDF, EPUB, or Word file. Everything is encrypted before it leaves this device."
                    : "Write a doc, or import a PDF, EPUB, or Word file. Everything is encrypted before it's stored, and can't be recovered on a new device yet."
            )
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                if folder != nil { breadcrumbs }
                if showsGrid { grid } else { list }
            }
        }
    }

    private var isEmptyLibrary: Bool {
        folder == nil && model.items.isEmpty && model.library.folders.isEmpty && model.trash.isEmpty && model.unreadable == 0
    }

    private var breadcrumbs: some View {
        let crumbs = model.library.path(to: folder)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s1) {
                Button("Reader") { path = [] }
                ForEach(Array(crumbs.dropLast().enumerated()), id: \.element.id) { index, crumb in
                    Image(systemName: "chevron.right")
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textTertiary.color)
                        .accessibilityHidden(true)
                    Button(crumb.displayTitle) {
                        path = crumbs.prefix(index + 1).map { .folder($0.id) }
                    }
                }
            }
            .font(Typeface.caption)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
        }
    }

    private var searchResults: some View {
        Group {
            if model.hits.isEmpty {
                ReaderMessage(systemImage: "magnifyingglass", title: "No matches", detail: "Search looks through names and the text of your docs and files.")
            } else {
                List(model.hits) { hit in
                    NavigationLink(value: ReaderRoute.item(hit.item)) {
                        ReaderRow(item: hit.item, snippet: hit.snippet)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.unreadable > 0 {
            Label(unreadableText, systemImage: "lock.slash")
                .font(Typeface.caption)
                .foregroundStyle(theme.danger.color)
        }
        Label(
            model.isSynced ? "Encrypted, and backed up by sync." : "Encrypted here. It can't be recovered on a new device yet.",
            systemImage: model.isSynced ? "lock" : "iphone"
        )
        .font(Typeface.caption)
        .foregroundStyle(theme.textSecondary.color)
    }

    private var unreadableText: String {
        model.unreadable == 1
            ? "1 item can't be opened on this device."
            : "\(model.unreadable) items can't be opened on this device."
    }

    private var isEmptyFolder: Bool {
        contents.folders.isEmpty && contents.items.isEmpty
    }

    private func route(for entry: ReaderItem) -> ReaderRoute {
        entry.kind == .folder ? .folder(entry.id) : .item(entry)
    }

    private func detail(for entry: ReaderItem) -> String? {
        guard entry.kind == .folder else { return nil }
        let count = insideCount(entry)
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var list: some View {
        List {
            if folder == nil {
                status
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if isEmptyFolder {
                Text(folder == nil ? "Nothing at the top level." : "This folder is empty. Add a doc, or import a file here.")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(contents.folders + contents.items) { entry in
                NavigationLink(value: route(for: entry)) {
                    ReaderRow(item: entry, snippet: detail(for: entry))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { requestDelete(entry) }
                    Button("Move", systemImage: "folder") { moving = entry }
                }
                .contextMenu { actions(for: entry) }
                .draggable(entry.id.uuidString)
                .modifier(FolderDropTarget(entry: entry, model: model))
            }
            if folder == nil { trashLink }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                if folder == nil { status }
                if isEmptyFolder {
                    Text(folder == nil ? "Nothing at the top level." : "This folder is empty. Add a doc, or import a file here.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Space.s8 * 2 + Space.s5), spacing: Space.s4)], spacing: Space.s4) {
                    ForEach(contents.folders + contents.items) { entry in
                        NavigationLink(value: route(for: entry)) {
                            ReaderTile(item: entry, detail: detail(for: entry) ?? entry.detail)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { actions(for: entry) }
                        .draggable(entry.id.uuidString)
                        .modifier(FolderDropTarget(entry: entry, model: model))
                    }
                }
                if folder == nil { trashLink }
            }
            .padding(Space.s4)
        }
    }

    private var trashLink: some View {
        NavigationLink(value: ReaderRoute.trash) {
            Label(model.trash.isEmpty ? "Recently Deleted" : "Recently Deleted (\(model.trash.count))", systemImage: "trash")
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder private func actions(for entry: ReaderItem) -> some View {
        Button("Rename", systemImage: "pencil") {
            name = entry.title
            renaming = entry
        }
        Button("Move", systemImage: "folder") { moving = entry }
        Button("Delete", systemImage: "trash", role: .destructive) { requestDelete(entry) }
    }

    /// Only a folder with things in it asks, because anything deleted can be restored.
    private func requestDelete(_ entry: ReaderItem) {
        if entry.kind == .folder, !model.library.descendants(of: entry.id).isEmpty {
            deleting = entry
        } else {
            Task { await model.delete(entry) }
        }
    }
}

/// Lets a folder take what's dragged onto it.
private struct FolderDropTarget: ViewModifier {
    let entry: ReaderItem
    let model: ReaderModel

    func body(content: Content) -> some View {
        if entry.kind == .folder {
            content.dropDestination(for: String.self) { ids, _ in
                let moved = ids.compactMap(UUID.init(uuidString:))
                Task {
                    for id in moved { await model.move(id: id, to: entry.id) }
                }
                return !moved.isEmpty
            }
        } else {
            content
        }
    }
}

/// One item in the grid view.
struct ReaderTile: View {
    let item: ReaderItem
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Image(systemName: item.systemImage)
                .font(Typeface.title)
                .foregroundStyle(item.kind == .folder ? theme.accent.color : theme.textSecondary.color)
                .accessibilityHidden(true)
            Spacer(minLength: Space.s3)
            Text(item.displayTitle)
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(detail)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, minHeight: Space.s8 * 2, alignment: .leading)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityElement(children: .combine)
    }
}

/// Picks where something goes. A folder can't be chosen as its own destination.
private struct ReaderMoveSheet: View {
    let entry: ReaderItem
    let library: ReaderLibrary
    let onChoose: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Choice: Identifiable {
        let folder: ReaderItem
        let depth: Int
        var id: UUID { folder.id }
    }

    private func choices(in parent: UUID?, depth: Int) -> [Choice] {
        library.contents(of: parent, sortedBy: .name).folders.flatMap {
            [Choice(folder: $0, depth: depth)] + choices(in: $0.id, depth: depth + 1)
        }
    }

    var body: some View {
        let theme = Theme.current
        let parent = library.parent(of: entry)
        NavigationStack {
            List {
                row("Reader", systemImage: "books.vertical", depth: 0, destination: nil, isEnabled: parent != nil)
                ForEach(choices(in: nil, depth: 1)) { choice in
                    row(
                        choice.folder.displayTitle, systemImage: "folder", depth: choice.depth, destination: choice.folder.id,
                        isEnabled: parent != choice.folder.id && library.canMove(entry, to: choice.folder.id)
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.bg.color)
            .navigationTitle("Move \(entry.displayTitle)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(theme.accent.color)
    }

    private func row(_ title: String, systemImage: String, depth: Int, destination: UUID?, isEnabled: Bool) -> some View {
        Button {
            onChoose(destination)
            dismiss()
        } label: {
            Label(title, systemImage: systemImage)
                .font(Typeface.body)
                .padding(.leading, Space.s4 * CGFloat(depth))
        }
        .disabled(!isEnabled)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
