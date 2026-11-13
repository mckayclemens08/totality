import PDFKit
import SwiftUI
import TotalityUI

/// Opens one item: an editor for docs, real pages for PDFs, reading text for everything else.
struct ReaderItemView: View {
    /// Holds only whether it's on, and it stays with the device.
    static let readAlongKey = "reader.readAlong"

    /// Its button is on the Listen bar, so it only applies while that bar is showing. Otherwise a note
    /// left with it on couldn't be edited, and nothing on the page could turn it off.
    static func appliesReadAlong(isOn: Bool, listen: ListenController) -> Bool {
        isOn && listen.current != nil
    }

    let item: ReaderItem
    let model: ReaderModel

    @AppStorage(Self.readAlongKey) private var readAlong = false

    var body: some View {
        let along = Self.appliesReadAlong(isOn: readAlong, listen: model.listen)
        Group {
            if item.kind == .note {
                NoteEditor(item: item, model: model, readAlong: along)
            } else if item.mime == "application/pdf" {
                PDFReader(item: item, model: model, readAlong: along)
            } else {
                FileReader(item: item, model: model, readAlong: along)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolbarIcon("Listen", systemImage: "headphones") {
                    Task { await model.startListening(to: item.id) }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarIcon("Add to Listen queue", systemImage: "text.badge.plus") {
                    Task { await model.addToQueue(item.id) }
                }
            }
        }
    }
}

/// Reading text for EPUB, Word, and plain files, with chapters when there are any.
private struct FileReader: View {
    let item: ReaderItem
    let model: ReaderModel
    let readAlong: Bool

    @State private var document: ReadableDocument?
    /// What Listen reads, which isn't always what the document's paragraphs add up to.
    @State private var text: String?
    @State private var problem: String?
    @State private var target: Int?
    @State private var chapter: String?

    private var chapters: [(index: Int, title: String)] {
        (document?.sections ?? []).enumerated().compactMap { index, section in
            section.title.map { (index, $0) }
        }
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if readAlong, let text, let document {
                ReadAlongView(item: item, model: model, text: text, headings: headings(of: document), chapter: $chapter)
            } else if let document {
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(chapters, id: \.index) { chapter in
                            Button(chapter.title) {
                            target = chapter.index
                            self.chapter = chapter.title
                        }
                        }
                    } label: {
                        ToolbarGlyph(systemImage: "list.bullet").accessibilityLabel("Chapters")
                    }
                }
            }
        }
        .task {
            do {
                document = try await model.document(of: item.id)
                text = try await model.text(of: item.id)
                // Listen is likely next, and a long book takes seconds to split. The page shows first.
                Task { await model.prepareListening(to: item.id) }
            } catch let error as ReaderError {
                problem = error.message
            } catch {
                problem = "It may have been damaged, or it may belong to another key."
            }
        }
    }

    private func headings(of document: ReadableDocument) -> Set<String> {
        Set(document.sections.flatMap(\.blocks).filter(\.isHeading).map(\.text))
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
    let readAlong: Bool

    @State private var document: PDFDocument?
    @State private var data: Data?
    @State private var problem: String?
    @State private var along: PDFAlong?
    @State private var isFollowing = true

    /// What Listen reads, and where it falls on the pages.
    private struct PDFAlong: Sendable {
        let script: ListenScript
        let map: PDFPageMap
    }

    private var highlight: ReadAlongHighlight? {
        guard readAlong, let along, let current = model.listen.current, current.id == item.id,
              current.script.fingerprint == along.script.fingerprint
        else { return nil }
        return along.script.highlight(sentence: model.listen.sentence, spoken: model.listen.spoken)
    }

    private var follow: PDFFollow? {
        guard readAlong, let along, !along.script.sentences.isEmpty else { return nil }
        return PDFFollow(
            map: along.map, highlight: highlight, isFollowing: isFollowing,
            onTap: { offset in
                isFollowing = true
                Task { await model.listen(to: item.id, from: offset, on: along.script) }
            },
            onScroll: { isFollowing = false }
        )
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if let document {
                PDFPages(document: document, follow: follow)
                    .overlay(alignment: .bottom) {
                        if readAlong, along?.script.sentences.isEmpty == true {
                            Text("This PDF has no text to follow.")
                                .font(Typeface.callout)
                                .foregroundStyle(theme.textSecondary.color)
                                .padding(.horizontal, Space.s4)
                                .padding(.vertical, Space.s3)
                                .neumorphic(.raised, in: Capsule())
                                .padding(.bottom, Space.s3)
                        } else if highlight != nil, !isFollowing {
                            BackToReading { isFollowing = true }
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
        // The file may still be loading when this first runs, so it runs again once the data is here.
        .task(id: readAlong && data != nil) {
            guard readAlong, along == nil, let data, let text = try? await model.text(of: item.id) else { return }
            // Both take a while in a long file, so neither holds up the pages.
            along = await Task.detached {
                PDFAlong(script: ListenScript(text: text), map: ReadableText.pageMap(data))
            }.value
        }
        .task {
            do {
                let data = try await model.fileData(of: item.id)
                guard let opened = PDFDocument(data: data) else {
                    problem = ReaderError.notReadable.message
                    return
                }
                if opened.isLocked {
                    problem = ReaderError.passwordProtected.message
                } else {
                    document = opened
                    self.data = data
                    // Listen is likely next, and a long book takes seconds to split. The pages show first.
                    Task { await model.prepareListening(to: item.id) }
                }
            } catch let error as ReaderError {
                problem = error.message
            } catch {
                problem = "It may have been damaged, or it may belong to another key."
            }
        }
    }
}

/// Read along on a PDF's own pages.
private struct PDFFollow {
    let map: PDFPageMap
    let highlight: ReadAlongHighlight?
    let isFollowing: Bool
    let onTap: (Int) -> Void
    let onScroll: () -> Void
}

/// A PDF's links are the file's own, so they pass the same check as a doc's before anything opens.
@MainActor
private final class PDFLinks: NSObject, @preconcurrency PDFViewDelegate {
    var open: OpenURLAction?
    private var follow: PDFFollow?
    private var shown: ReadAlongHighlight?
    private var sentence: [PDFSelection] = []
    private let scrollWatch = ScrollWatch()

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if DocText.isOpenable(url) { open?(url) }
    }

    func update(_ view: PDFView, follow: PDFFollow?) {
        let wasFollowing = self.follow?.isFollowing ?? false
        self.follow = follow
        scrollWatch.onScroll = { [weak self] in self?.follow?.onScroll() }
        scrollWatch.watch(view)
        guard follow?.highlight != shown || follow?.isFollowing != wasFollowing else { return }
        let moved = follow?.highlight?.sentence != shown?.sentence
        shown = follow?.highlight
        guard let follow, let highlight = follow.highlight else {
            sentence = []
            view.highlightedSelections = nil
            return
        }
        if moved { sentence = selections(follow.map, highlight.range, in: view, color: Theme.current.highlight) }
        let word = highlight.word.map { selections(follow.map, $0, in: view, color: Theme.current.highlightStrong) } ?? []
        view.highlightedSelections = sentence + word
        if follow.isFollowing, moved || !wasFollowing, let first = sentence.first, !isOnScreen(first, in: view) {
            view.go(to: first)
        }
    }

    private func selections(_ map: PDFPageMap, _ range: Range<Int>, in view: PDFView, color: ColorToken) -> [PDFSelection] {
        map.pieces(of: range).compactMap { piece in
            let selection = view.document?.page(at: piece.page)?.selection(for: piece.range)
            selection?.color = color.platformColor
            return selection
        }
    }

    private func isOnScreen(_ selection: PDFSelection, in view: PDFView) -> Bool {
        guard let page = selection.pages.first else { return true }
        let bounds = view.convert(selection.bounds(for: page), from: page)
        return view.bounds.contains(bounds)
    }

    /// A tap on a sentence. A tap on a link is the link's, and a tap on blank page does nothing.
    fileprivate func tapped(at point: CGPoint, in view: PDFView) {
        guard let follow, let page = view.page(for: point, nearest: false) else { return }
        let onPage = view.convert(point, to: page)
        guard page.annotation(at: onPage)?.url == nil else { return }
        let character = page.characterIndex(at: onPage)
        guard character != NSNotFound, let document = view.document,
              let offset = follow.map.offset(page: document.index(for: page), character: character)
        else { return }
        follow.onTap(offset)
    }
}

#if canImport(UIKit)
private struct PDFPages: UIViewRepresentable {
    let document: PDFDocument
    let follow: PDFFollow?

    func makeCoordinator() -> PDFLinks { PDFLinks() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.delegate = context.coordinator
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = Theme.current.bg.platformColor
        view.document = document
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(PDFLinks.tap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.open = context.environment.openURL
        if view.document !== document { view.document = document }
        context.coordinator.update(view, follow: follow)
    }
}

extension PDFLinks: UIGestureRecognizerDelegate {
    @objc fileprivate func tap(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view as? PDFView else { return }
        tapped(at: recognizer.location(in: view), in: view)
    }

    /// The PDF view has its own taps, and they should all still work.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#else
private struct PDFPages: NSViewRepresentable {
    let document: PDFDocument
    let follow: PDFFollow?

    func makeCoordinator() -> PDFLinks { PDFLinks() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.delegate = context.coordinator
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = Theme.current.bg.platformColor
        view.document = document
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(PDFLinks.click))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.open = context.environment.openURL
        if view.document !== document { view.document = document }
        context.coordinator.update(view, follow: follow)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: PDFLinks) {
        coordinator.stop()
    }
}

extension PDFLinks {
    @objc fileprivate func click(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view as? PDFView else { return }
        tapped(at: recognizer.location(in: view), in: view)
    }

    fileprivate func stop() {
        scrollWatch.stop()
    }
}
#endif
