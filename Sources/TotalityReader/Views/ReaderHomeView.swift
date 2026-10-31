import SwiftUI
import TotalityUI

enum ReaderRoute: Hashable {
    case folder(UUID)
    case item(ReaderItem)
    case trash
}

/// The Reader's front door: the top of the library, and everything that outlives one screen.
public struct ReaderHomeView: View {
    @Bindable private var model: ReaderModel
    private let onClose: (() -> Void)?
    @State private var path: [ReaderRoute] = []

    private static let searchPause = Duration.milliseconds(250)

    public init(model: ReaderModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ReaderFolderView(folder: nil, model: model, path: $path, onClose: onClose)
                .navigationDestination(for: ReaderRoute.self) { route in
                    switch route {
                    case .folder(let id):
                        ReaderFolderView(folder: id, model: model, path: $path, onClose: nil)
                    case .item(let item):
                        ReaderItemView(item: item, model: model)
                    case .trash:
                        ReaderTrashView(model: model)
                    }
                }
                .searchable(text: $model.query, prompt: "Search titles and text")
        }
        .tint(Theme.current.accent.color)
        .safeAreaInset(edge: .bottom) {
            if model.listen.current != nil {
                ListenBar(listen: model.listen)
                    .padding(Space.s3)
                    .background(Theme.current.bg.color)
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
                path = [.item(item)]
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
}

extension ReaderItem {
    var systemImage: String {
        switch typeName {
        case "Folder": "folder"
        case "Doc": "doc.text"
        case "PDF": "doc.richtext"
        case "EPUB": "book.closed"
        case "Word": "doc.plaintext"
        default: "doc"
        }
    }

    /// The quiet line under a name.
    var detail: String {
        let date = updatedAt.formatted(date: .abbreviated, time: .omitted)
        return kind == .note ? date : "\(typeName) · \(date)"
    }
}

struct ReaderRow: View {
    let item: ReaderItem
    let snippet: String?

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.kind == .folder ? theme.accent.color : theme.textSecondary.color)
                .frame(width: Space.s5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(item.displayTitle)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                Text(snippet ?? item.detail)
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
