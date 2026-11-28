import SwiftUI
import TotalityCore
import TotalityUI

/// A shared doc open (issue 228). Editors write in the same writing page as a private doc; a save posts
/// only the paragraphs they changed. Viewers read it. Others' changes come in while it's open.
struct SharedDocScreen: View {
    let room: String
    let model: ReaderModel
    let shared: SharedDocsModel
    @Environment(\.dismiss) private var dismiss

    private static let savePause = Duration.milliseconds(900)
    private static let pollPause = Duration.seconds(6)

    @State private var editor = WritingEditorController()
    /// The blocks the editor's text was last matched to. A save posts what changed since.
    @State private var base: [SharedBlock]?
    /// The editor revision that matches `base`, so typing since then is known to be unsaved.
    @State private var savedRevision = 0
    @State private var isSaving = false
    @State private var title = ""
    /// The title as the room last had it, so a title being typed isn't overwritten.
    @State private var postedTitle = ""
    @State private var showsPeople = false
    @State private var showsInvite = false

    private var doc: SharedDocState? { shared.doc(room) }
    private var canEdit: Bool { shared.canEdit(room) }

    var body: some View {
        let theme = Theme.current
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg.color)
            .navigationTitle(doc?.displayTitle ?? "Shared doc")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("People", systemImage: "person.2") { showsPeople = true }
                        if let doc, doc.isComplete {
                            Button("Save to my Reader", systemImage: "doc.badge.plus") {
                                Task {
                                    await flushAndSave()
                                    if await model.keepPrivateCopy(title: doc.title, text: doc.text) != nil {
                                        shared.notice = "Saved to the top of your Reader."
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("People", systemImage: "person.2")
                    }
                }
            }
            .sheet(isPresented: $showsPeople) {
                SharedPeopleSheet(
                    model: model, shared: shared, room: room,
                    onInvite: {
                        showsPeople = false
                        showsInvite = true
                    },
                    onGone: { dismiss() },
                    onDone: { showsPeople = false }
                )
            }
            .sheet(isPresented: $showsInvite) {
                ShareDocSheet(model: model, shared: shared, target: .room(room)) { _ in showsInvite = false }
            }
            .alert("Shared doc", isPresented: Binding(get: { shared.notice != nil }, set: { if !$0 { shared.notice = nil } })) {
                Button("OK", role: .cancel) { shared.notice = nil }
            } message: {
                Text(shared.notice ?? "")
            }
            .task {
                await shared.reload(room)
                await open()
            }
            .task(id: editor.revision) {
                guard base != nil, editor.revision != savedRevision else { return }
                try? await Task.sleep(for: Self.savePause)
                guard !Task.isCancelled else { return }
                await save()
            }
            .task {
                // Others' changes arrive while it's open, a few seconds apart.
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pollPause)
                    guard !Task.isCancelled else { return }
                    await catchUp()
                }
            }
            .onDisappear {
                Task { await flushAndSave() }
            }
    }

    @ViewBuilder private var content: some View {
        let theme = Theme.current
        if doc == nil {
            ReaderMessage(
                systemImage: "person.2.slash",
                title: "This doc isn't shared with you now",
                detail: "Its owner may have stopped sharing it, or removed you."
            )
        } else if let doc, !doc.isComplete {
            ReaderMessage(
                systemImage: "hourglass",
                title: "Waiting for doc",
                detail: "You joined after this doc was shared. It opens when an editor next has Totality open."
            )
        } else if canEdit {
            VStack(alignment: .leading, spacing: Space.s2) {
                TextField("Title", text: $title)
                    .font(Typeface.title)
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.textPrimary.color)
                    .padding(.horizontal, Space.s4)
                    .padding(.top, Space.s4)
                    .onSubmit { Task { await shared.rename(room, to: title) } }
                statusLine
                    .padding(.horizontal, Space.s4)
                WritingEditorView(controller: editor, webView: editor.webView)
                    .overlay {
                        if base == nil || editor.phase == .starting {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(theme.bg.color)
                        }
                    }
            }
            .safeAreaInset(edge: .bottom) {
                WritingFormatBar(controller: editor, onCite: {}, onCrossRef: {}, onDocLink: {})
                    .background(theme.bg.color)
            }
        } else if let doc {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text(doc.displayTitle)
                        .font(Typeface.title)
                        .foregroundStyle(theme.textPrimary.color)
                    statusLine
                    ForEach(doc.visibleBlocks) { block in
                        SharedBlockText(text: block.text)
                    }
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await shared.reload(room) }
        }
    }

    private var statusLine: some View {
        let others = (doc?.members.count ?? 1) - 1
        let people = others == 1 ? "Shared with 1" : "Shared with \(others)"
        let role = canEdit ? (isSaving ? "saving" : (editor.revision == savedRevision ? "saved" : "editing")) : "you can view"
        return SharedEncryptedLine(text: "\(people) · \(role)")
    }

    /// Puts the doc in the editor once the room has it.
    private func open() async {
        guard let doc, doc.isComplete else { return }
        title = doc.title
        postedTitle = doc.title
        guard canEdit else { return }
        await editor.start()
        editor.load(doc.text, docs: model.docTitles)
        base = doc.visibleBlocks
        savedRevision = editor.revision
    }

    private func flushAndSave() async {
        guard canEdit, base != nil else { return }
        await editor.flush()
        await save()
        if let doc, title != doc.title { await shared.rename(room, to: title) }
    }

    /// One at a time; anything typed while a save runs lands on the next loop.
    private func save() async {
        guard !isSaving, var current = base else { return }
        isSaving = true
        defer { isSaving = false }
        while editor.revision != savedRevision {
            let revision = editor.revision
            guard let after = await shared.save(room, base: current, text: editor.text) else { return }
            current = after
            base = after
            savedRevision = revision
        }
    }

    /// Reads the room again. With nothing unsaved here, the editor takes others' changes.
    private func catchUp() async {
        let wasComplete = doc?.isComplete == true
        await shared.reload(room)
        guard let doc, doc.isComplete else { return }
        if !wasComplete || (canEdit && base == nil) {
            await open()
            return
        }
        // A title typed here and not posted yet stays; otherwise the room's wins.
        if title == postedTitle, doc.title != title {
            title = doc.title
        }
        postedTitle = doc.title
        guard canEdit, !isSaving, let base else { return }
        await editor.flush()
        guard editor.revision == savedRevision, doc.visibleBlocks != base else { return }
        if doc.text != editor.text {
            editor.load(doc.text, docs: model.docTitles)
        }
        self.base = doc.visibleBlocks
        savedRevision = editor.revision
    }
}

/// One block of a doc for reading: a heading, or a paragraph with its inline Markdown.
struct SharedBlockText: View {
    let text: String

    var body: some View {
        let theme = Theme.current
        let level = text.prefix { $0 == "#" }.count
        if (1...6).contains(level), text.dropFirst(level).first == " " {
            Text(String(text.dropFirst(level + 1)))
                .font(level <= 2 ? Typeface.title : Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
        } else {
            Text(Self.attributed(text))
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Someone else wrote this, so only web links stay tappable.
    static func attributed(_ text: String) -> AttributedString {
        guard var styled = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in styled.runs {
            if let link = run.link, !["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                styled[run.range].link = nil
            }
        }
        return styled
    }
}
