import SwiftUI
import TotalityUI

/// The Reader's front screen: everything the person keeps, with search and Listen.
public struct ReaderHomeView: View {
    @Bindable private var model: ReaderModel
    private let onClose: (() -> Void)?
    @State private var path: [ReaderItem] = []
    @State private var importing = false
    @State private var importCollection: String?

    private static let searchPause = Duration.milliseconds(250)

    public init(model: ReaderModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Theme.current.bg.color)
                .navigationTitle("Reader")
                .navigationDestination(for: ReaderItem.self) { item in
                    ReaderItemView(item: item, model: model)
                }
                .searchable(text: $model.query, prompt: "Search titles and text")
                .toolbar { toolbar }
        }
        .tint(Theme.current.accent.color)
        .safeAreaInset(edge: .bottom) {
            if model.listen.current != nil {
                ListenBar(listen: model.listen)
                    .padding(Space.s3)
                    .background(Theme.current.bg.color)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let toSpeechify = importCollection != nil
                Task {
                    if toSpeechify {
                        await model.importSpeechify(urls)
                    } else {
                        await model.importFiles(urls)
                    }
                }
            } else if case .failure = result {
                model.notice = "Those files couldn't be opened."
            }
        }
        .alert("Reader", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .task { await model.load() }
        .task(id: model.requestedItem) {
            guard let id = model.requestedItem else { return }
            model.requestedItem = nil
            if let item = try? await model.currentItem(id) {
                path = [item]
            } else {
                model.notice = ReaderError.notFound.message
            }
        }
        .task(id: model.query) {
            try? await Task.sleep(for: Self.searchPause)
            guard !Task.isCancelled else { return }
            await model.search()
        }
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
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New note", systemImage: "square.and.pencil") { createNote() }
                Button("Import files", systemImage: "square.and.arrow.down") { startImport(into: nil) }
                Button("Import into \(ReaderItem.speechifyCollection)", systemImage: "books.vertical") {
                    startImport(into: ReaderItem.speechifyCollection)
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private func createNote() {
        Task {
            if let item = await model.newNote() { path.append(item) }
        }
    }

    private func startImport(into collection: String?) {
        importCollection = collection
        importing = true
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
        case .ready where model.isSearching:
            searchResults
        case .ready where model.items.isEmpty && model.unreadable == 0:
            ReaderMessage(
                systemImage: "book",
                title: "Nothing here yet",
                detail: model.isSynced
                    ? "Write a note, or import a PDF or text file. Everything is encrypted before it leaves this device."
                    : "Write a note, or import a PDF or text file. Everything is encrypted before it's stored, and can't be recovered on a new device yet."
            )
        case .ready:
            library
        }
    }

    @ViewBuilder private var searchResults: some View {
        if model.hits.isEmpty {
            ReaderMessage(systemImage: "magnifyingglass", title: "No matches", detail: "Search looks through titles, notes, text files, and PDFs.")
        } else {
            List(model.hits) { hit in
                NavigationLink(value: hit.item) {
                    ReaderRow(item: hit.item, snippet: hit.snippet)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var library: some View {
        List {
            if model.unreadable > 0 {
                Label(unreadableText, systemImage: "lock.slash")
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.danger.color)
                    .listRowBackground(Color.clear)
            }
            Label(
                model.isSynced ? "Encrypted, and backed up by sync." : "Encrypted here. It can't be recovered on a new device yet.",
                systemImage: model.isSynced ? "lock" : "iphone"
            )
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.textSecondary.color)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(model.items) { item in
                NavigationLink(value: item) {
                    ReaderRow(item: item, snippet: nil)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await model.delete(item) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var unreadableText: String {
        model.unreadable == 1
            ? "1 item can't be opened on this device."
            : "\(model.unreadable) items can't be opened on this device."
    }
}

struct ReaderRow: View {
    let item: ReaderItem
    let snippet: String?

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Image(systemName: item.kind == .note ? "note.text" : "doc")
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(item.displayTitle)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                Text(snippet ?? item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s1)
        .accessibilityElement(children: .combine)
    }
}

struct ReaderMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(Typeface.display)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
