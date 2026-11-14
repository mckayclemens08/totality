import SwiftUI
import TotalityUI

/// A doc open for writing: its title, the writing page, and the format bar. Opens and saves through the
/// same path the Reader always has, and converts an older doc to Markdown the first time it opens.
struct NoteEditor: View {
    let item: ReaderItem
    let model: ReaderModel
    let readAlong: Bool

    private struct Draft: Equatable {
        var title: String
        var revision: Int
    }

    private static let savePause = Duration.milliseconds(600)

    @State private var editor = WritingEditorController()
    @State private var title = ""
    /// Nil until the doc has loaded, so an empty editor can never overwrite the stored doc.
    @State private var saved: Draft?
    /// The version the editor loaded, so a save can tell if the doc moved on underneath it.
    @State private var version: Date?
    @State private var isSaving = false
    @State private var failed = false
    /// The read-only copy an older doc was converted from, until the person says the new one is right.
    @State private var keptOriginal: UUID?
    @State private var linkAddress = ""
    @State private var chapter: String?
    @Environment(\.openURL) private var openURL

    private var draft: Draft {
        Draft(title: title, revision: editor.revision)
    }

    private var editingLink: Binding<Bool> {
        Binding(get: { editor.linkRequest != nil }, set: { if !$0 { editor.linkRequest = nil } })
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if failed {
                ReaderMessage(
                    systemImage: "lock.slash",
                    title: "This doc didn't open",
                    detail: "It may have been damaged, or it may belong to another key."
                )
            } else if case .failed(let reason) = editor.phase {
                VStack(spacing: Space.s4) {
                    ReaderMessage(systemImage: "exclamationmark.triangle", title: "The writing page didn't start", detail: reason)
                    Button("Try again") { Task { await editor.retry() } }
                        .buttonStyle(.plain)
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                        .padding(.bottom, Space.s6)
                }
            } else if saved != nil, readAlong {
                let words = editor.text
                ReadAlongView(
                    item: item, model: model, text: MarkdownText.plainText(words),
                    headings: Set(MarkdownText.headings(words).map(\.text)),
                    chapter: $chapter
                )
                .navigationTitle(item.displayTitle)
            } else {
                writing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.color)
        .alert("Link", isPresented: editingLink) {
            TextField("Web address", text: $linkAddress)
                .autocorrectionDisabled()
            Button("Save") { editor.run("link", linkAddress) }
            if let link = URL(string: editor.format.link), DocText.isOpenable(link) {
                Button("Open") { openURL(link) }
                Button("Remove", role: .destructive) { editor.run("link", "") }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: editor.linkRequest) {
            if let address = editor.linkRequest { linkAddress = address }
        }
        .task {
            editor.onOpen = { url in openURL(url) }
            await editor.start()
            await reload()
            await model.prepareListening(to: item.id)
        }
        // Listen reads what's saved, so anything just typed has to get there first.
        .onChange(of: readAlong) {
            Task {
                await editor.flush()
                await save()
            }
        }
        .onChange(of: model.items) {
            // A sync brought a newer version. With nothing unsaved here, the editor just catches up.
            guard draft == saved, let latest = model.items.first(where: { $0.id == item.id }),
                  latest.updatedAt != version
            else { return }
            Task { await reload() }
        }
        .task(id: draft) {
            try? await Task.sleep(for: Self.savePause)
            guard !Task.isCancelled else { return }
            await save()
        }
        .onDisappear {
            Task {
                await editor.flush()
                await save()
            }
        }
    }

    private var writing: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            TextField("Title", text: $title)
                .font(Typeface.title)
                .textFieldStyle(.plain)
                .foregroundStyle(theme.textPrimary.color)
                .padding(.horizontal, Space.s4)
                .padding(.top, Space.s4)
            if let keptOriginal {
                ConversionNotice(
                    onConfirm: {
                        Task {
                            if await model.confirmConversion(item.id) { self.keptOriginal = nil }
                        }
                    },
                    onShowOriginal: { model.requestedItem = keptOriginal }
                )
            }
            WritingEditorView(controller: editor)
                .overlay {
                    if saved == nil || editor.phase == .starting {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(theme.bg.color)
                    }
                }
        }
        .safeAreaInset(edge: .bottom) {
            WritingFormatBar(controller: editor)
        }
    }

    private func reload() async {
        do {
            // The navigation value can be out of date, so only its ID is trusted.
            let opened = try await model.loadMarkdown(item.id)
            editor.load(opened.text)
            title = opened.item.title
            keptOriginal = opened.item.keptOriginalID
            saved = Draft(title: opened.item.title, revision: editor.revision)
            version = opened.item.updatedAt
        } catch {
            failed = true
        }
    }

    /// One at a time, because a second save sent from the same version would look like a conflict.
    /// It loops so that anything typed while a save was running still lands.
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        while let saved, let version, draft != saved {
            let current = draft
            switch await model.saveMarkdown(item.id, title: current.title, text: editor.text, basedOn: version) {
            case .saved(let item):
                self.saved = current
                self.version = item.updatedAt
            case .keptAsCopy:
                // The model opens the copy. Matching here stops this editor making another one.
                self.saved = current
                return
            case nil:
                return
            }
        }
    }
}

/// Says an older doc was converted, and that its original is kept until the person is happy.
struct ConversionNotice: View {
    let onConfirm: () -> Void
    let onShowOriginal: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("This doc now opens in the new editor")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("It was converted to Markdown. The original is kept as a read-only copy beside it until you say this looks right.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s4) {
                Button("Looks right", action: onConfirm)
                    .foregroundStyle(theme.accent.color)
                Button("See the original", action: onShowOriginal)
                    .foregroundStyle(theme.textPrimary.color)
            }
            .font(Typeface.callout)
            .buttonStyle(.plain)
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .padding(.horizontal, Space.s4)
    }
}

/// Headings, emphasis, lists, quotes and links, always within reach. On the Mac the same commands have
/// shortcuts: Command-B, Command-I, Command-K, Command-Option-1 to 3, and Command-Shift-7 and 8.
struct WritingFormatBar: View {
    let controller: WritingEditorController

    var body: some View {
        let format = controller.format
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                textButton("H1", label: "Heading", isOn: format.heading == 1) { controller.run("heading", 1) }
                textButton("H2", label: "Subheading", isOn: format.heading == 2) { controller.run("heading", 2) }
                textButton("H3", label: "Minor heading", isOn: format.heading == 3) { controller.run("heading", 3) }
                iconButton("bold", label: "Bold", isOn: format.bold) { controller.run("bold") }
                iconButton("italic", label: "Italic", isOn: format.italic) { controller.run("italic") }
                iconButton("list.bullet", label: "Bulleted list", isOn: format.list == "bullet") { controller.run("bullet") }
                iconButton("list.number", label: "Numbered list", isOn: format.list == "numbered") { controller.run("numbered") }
                iconButton("checklist", label: "Checklist", isOn: format.list == "task") { controller.run("task") }
                iconButton("text.quote", label: "Quote", isOn: format.quote) { controller.run("quote") }
                iconButton("link", label: "Link", isOn: !format.link.isEmpty) { controller.linkRequest = format.link }
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
        }
        .background(Theme.current.bg.color)
        .disabled(controller.phase != .ready)
    }

    private func textButton(_ text: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        button(label: label, isOn: isOn, action: action) {
            Text(text).font(Typeface.callout)
        }
    }

    private func iconButton(_ name: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        button(label: label, isOn: isOn, action: action) {
            Image(systemName: name).font(Typeface.callout)
        }
    }

    private func button(label: String, isOn: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        let theme = Theme.current
        return Button(action: action) {
            content()
                .foregroundStyle(isOn ? theme.accent.color : theme.textPrimary.color)
                .frame(width: Space.s6 + Space.s2, height: Space.s6 + Space.s2)
                .neumorphic(isOn ? .pressed : .subtle, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
