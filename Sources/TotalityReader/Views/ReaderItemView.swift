import SwiftUI
import TotalityUI

/// Opens one item: an editor for notes, reading text for files.
struct ReaderItemView: View {
    let item: ReaderItem
    let model: ReaderModel

    var body: some View {
        Group {
            if item.kind == .note {
                NoteEditor(item: item, model: model)
            } else {
                FileReader(item: item, model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Listen", systemImage: "headphones") {
                    Task { await model.startListening(to: item.id) }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Add to Listen queue", systemImage: "text.badge.plus") {
                    Task { await model.addToQueue(item.id) }
                }
            }
        }
    }
}

private struct NoteEditor: View {
    let item: ReaderItem
    let model: ReaderModel

    private struct Draft: Equatable {
        var title: String
        var body: String
    }

    private static let savePause = Duration.milliseconds(600)

    @State private var draft: Draft?
    @State private var saved: Draft?
    @State private var failed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.current(scheme)
        Group {
            // The fields wait for the load: an empty editor must never overwrite the stored note.
            if let draft {
                VStack(alignment: .leading, spacing: Space.s3) {
                    TextField("Title", text: Binding(get: { draft.title }, set: { self.draft?.title = $0 }))
                        .font(Typeface.title)
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary.color)
                    TextEditor(text: Binding(get: { draft.body }, set: { self.draft?.body = $0 }))
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .scrollContentBackground(.hidden)
                }
                .padding(Space.s4)
            } else if failed {
                ReaderMessage(
                    systemImage: "lock.slash",
                    title: "This note didn't open",
                    detail: "It may have been damaged, or it may belong to another key."
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.color)
        .task {
            do {
                let loaded = Draft(title: item.title, body: try await model.loadNote(item.id))
                saved = loaded
                draft = loaded
            } catch {
                failed = true
            }
        }
        .task(id: draft) {
            try? await Task.sleep(for: Self.savePause)
            guard !Task.isCancelled else { return }
            await save()
        }
        .onDisappear {
            Task { await save() }
        }
    }

    private func save() async {
        guard let draft, draft != saved else { return }
        if await model.saveNote(item.id, title: draft.title, body: draft.body) { saved = draft }
    }
}

private struct FileReader: View {
    let item: ReaderItem
    let model: ReaderModel

    @State private var paragraphs: [String]?
    @State private var problem: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.current(scheme)
        Group {
            if let paragraphs {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s3) {
                        ForEach(paragraphs.indices, id: \.self) { index in
                            Text(paragraphs[index])
                                .font(Typeface.body)
                                .foregroundStyle(theme.textPrimary.color)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(Space.s4)
                }
            } else if let problem {
                ReaderMessage(systemImage: "doc.questionmark", title: "This can't be shown", detail: problem)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.color)
        .navigationTitle(item.displayTitle)
        .task {
            do {
                paragraphs = try await model.text(of: item.id)
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
            } catch let error as ReaderError {
                problem = error.message
            } catch {
                problem = "It may have been damaged, or it may belong to another key."
            }
        }
    }
}
