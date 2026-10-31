import PDFKit
import SwiftUI
import TotalityUI

/// Opens one item: an editor for docs, real pages for PDFs, reading text for everything else.
struct ReaderItemView: View {
    let item: ReaderItem
    let model: ReaderModel

    var body: some View {
        Group {
            if item.kind == .note {
                NoteEditor(item: item, model: model)
            } else if item.mime == "application/pdf" {
                PDFReader(item: item, model: model)
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
        var revision: Int
    }

    private static let savePause = Duration.milliseconds(600)

    @State private var editor = DocEditorController()
    @State private var title = ""
    /// Nil until the doc has loaded, so an empty editor can never overwrite the stored doc.
    @State private var saved: Draft?
    /// The version the editor loaded, so a save can tell if the doc moved on underneath it.
    @State private var version: Date?
    @State private var isSaving = false
    @State private var failed = false
    @State private var editingLink = false
    @State private var linkAddress = ""
    @Environment(\.openURL) private var openURL

    private var draft: Draft {
        Draft(title: title, revision: editor.revision)
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if saved != nil {
                VStack(alignment: .leading, spacing: Space.s2) {
                    TextField("Title", text: $title)
                        .font(Typeface.title)
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary.color)
                        .padding(.horizontal, Space.s4)
                        .padding(.top, Space.s4)
                    DocTextEditor(controller: editor)
                }
                .safeAreaInset(edge: .bottom) {
                    DocFormatBar(controller: editor) {
                        linkAddress = editor.currentLink?.absoluteString ?? ""
                        editingLink = true
                    }
                }
            } else if failed {
                ReaderMessage(
                    systemImage: "lock.slash",
                    title: "This doc didn't open",
                    detail: "It may have been damaged, or it may belong to another key."
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.color)
        .alert("Link", isPresented: $editingLink) {
            TextField("Web address", text: $linkAddress)
                .autocorrectionDisabled()
            Button("Save") { editor.setLink(address: linkAddress) }
            if let link = editor.currentLink {
                Button("Open") { openURL(link) }
                Button("Remove", role: .destructive) { editor.setLink(address: "") }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await reload() }
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
            Task { await save() }
        }
    }

    private func reload() async {
        do {
            // The navigation value can be out of date, so only its ID is trusted.
            let current = try await model.currentItem(item.id)
            editor.load(try await model.loadDoc(item.id))
            title = current.title
            saved = Draft(title: current.title, revision: editor.revision)
            version = current.updatedAt
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
            switch await model.saveDoc(item.id, title: current.title, doc: editor.document, basedOn: version) {
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

/// Reading text for EPUB, Word, and plain files, with chapters when there are any.
private struct FileReader: View {
    let item: ReaderItem
    let model: ReaderModel

    @State private var document: ReadableDocument?
    @State private var problem: String?
    @State private var target: Int?

    private var chapters: [(index: Int, title: String)] {
        (document?.sections ?? []).enumerated().compactMap { index, section in
            section.title.map { (index, $0) }
        }
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if let document {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Space.s5) {
                            ForEach(document.sections.indices, id: \.self) { index in
                                SectionText(section: document.sections[index])
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: Space.s8 * 10, alignment: .leading)
                        .padding(Space.s4)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: target) {
                        if let target { reader.scrollTo(target, anchor: .top) }
                    }
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
        .toolbar {
            if chapters.count > 1 {
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        ForEach(chapters, id: \.index) { chapter in
                            Button(chapter.title) { target = chapter.index }
                        }
                    } label: {
                        Label("Chapters", systemImage: "list.bullet")
                    }
                }
            }
        }
        .task {
            do {
                document = try await model.document(of: item.id)
            } catch let error as ReaderError {
                problem = error.message
            } catch {
                problem = "It may have been damaged, or it may belong to another key."
            }
        }
    }
}

private struct SectionText: View {
    let section: ReadableDocument.Section

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            ForEach(section.blocks.indices, id: \.self) { index in
                let block = section.blocks[index]
                Text(block.text)
                    .font(block.isHeading ? Typeface.title : Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineSpacing(Space.s1)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(block.isHeading ? .isHeader : [])
            }
        }
    }
}

/// A PDF's real pages. The file is decrypted into memory and never written anywhere.
private struct PDFReader: View {
    let item: ReaderItem
    let model: ReaderModel

    @State private var document: PDFDocument?
    @State private var problem: String?

    var body: some View {
        let theme = Theme.current
        Group {
            if let document {
                PDFPages(document: document)
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
                guard let opened = PDFDocument(data: try await model.fileData(of: item.id)) else {
                    problem = ReaderError.notReadable.message
                    return
                }
                if opened.isLocked {
                    problem = ReaderError.passwordProtected.message
                } else {
                    document = opened
                }
            } catch let error as ReaderError {
                problem = error.message
            } catch {
                problem = "It may have been damaged, or it may belong to another key."
            }
        }
    }
}

/// A PDF's links are the file's own, so they pass the same check as a doc's before anything opens.
@MainActor
private final class PDFLinks: NSObject, @preconcurrency PDFViewDelegate {
    var open: OpenURLAction?

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if DocText.isOpenable(url) { open?(url) }
    }
}

#if canImport(UIKit)
private struct PDFPages: UIViewRepresentable {
    let document: PDFDocument

    func makeCoordinator() -> PDFLinks { PDFLinks() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.delegate = context.coordinator
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = Theme.current.bg.platformColor
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.open = context.environment.openURL
        if view.document !== document { view.document = document }
    }
}
#else
private struct PDFPages: NSViewRepresentable {
    let document: PDFDocument

    func makeCoordinator() -> PDFLinks { PDFLinks() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.delegate = context.coordinator
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = Theme.current.bg.platformColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.open = context.environment.openURL
        if view.document !== document { view.document = document }
    }
}
#endif
