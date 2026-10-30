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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

    @State private var title = ""
    @State private var text = ""
    /// Nil until the note has loaded, so an empty editor can never overwrite the stored note.
    @State private var saved: Draft?
    @State private var failed = false
    @Environment(\.colorScheme) private var scheme

    private var draft: Draft {
        Draft(title: title, body: text)
    }

    var body: some View {
        let theme = Theme.current(scheme)
        Group {
            if saved != nil {
                VStack(alignment: .leading, spacing: Space.s3) {
                    TextField("Title", text: $title)
                        .font(Typeface.title)
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary.color)
                    TextEditor(text: $text)
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
                title = loaded.title
                text = loaded.body
                saved = loaded
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
        let current = draft
        guard let saved, current != saved else { return }
        if await model.saveNote(item.id, title: current.title, body: current.body) { self.saved = current }
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
