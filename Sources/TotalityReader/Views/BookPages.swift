import SwiftUI
import TotalityUI
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Runs one book's pages: which chapter is showing, which page of it, and the read-along marks.
@MainActor
@Observable
final class BookPageController: NSObject {
    enum Phase: Equatable {
        case starting, ready
        case failed(String)
    }

    private(set) var phase = Phase.starting
    private(set) var webView: WKWebView?
    private(set) var chapter = 0
    private(set) var page = 1
    private(set) var pages = 1
    /// What the page itself has to read, once it's set out. Zero means nothing to show.
    private(set) var textLength: Int?
    private(set) var scripts = 0
    /// Whether the pages turn to follow Listen. A swipe or scroll of the person's own stops it.
    var isFollowing = true
    var scrolls = false {
        didSet { if scrolls != oldValue { setUp(atEnd: false) } }
    }

    /// A tap on words, with the place in Listen's text.
    @ObservationIgnored var onTap: ((Int) -> Void)?
    /// A link out of the book, after the person tapped it.
    @ObservationIgnored var onOpen: ((URL) -> Void)?
    /// Where the person is: the chapter's path, how far through it from 0 to 1, and the place in Listen's text.
    @ObservationIgnored var onPlace: ((String, Double, Int?) -> Void)?

    @ObservationIgnored private(set) var source: BookSource?
    @ObservationIgnored private let files = BookFiles()
    @ObservationIgnored private var rules: WritingRules
    @ObservationIgnored private var shown: ReadAlongHighlight?
    @ObservationIgnored private var openAtEnd = false
    @ObservationIgnored private var openProgress = 0.0
    @ObservationIgnored private var isSetUp = false

    init(rules: WritingRules? = nil) {
        self.rules = rules ?? BookPage.sharedRules
    }

    var chapters: [BookSource.Chapter] { source?.chapters ?? [] }

    /// Opens the book, at a chapter and how far through it when there's a place to go back to.
    func start(_ source: BookSource, at place: (chapter: Int, progress: Double)? = nil) async {
        guard webView == nil else { return }
        guard let script = BookPage.script() else {
            phase = .failed("The book page is missing from this build.")
            return
        }
        guard let list = await rules.list() else {
            phase = .failed("The book couldn't be shut off from the internet, so it didn't open.")
            return
        }
        self.source = source
        files.source = source
        let view = BookWebView(frame: .zero, configuration: BookPage.configuration(rules: list, handler: BookRelay(self), files: files, script: script))
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsLinkPreview = false
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = Theme.current.bg.platformColor
        view.scrollView.backgroundColor = Theme.current.bg.platformColor
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        view.underPageBackgroundColor = Theme.current.bg.platformColor
        view.allowsMagnification = false
        #endif
        webView = view
        if let place, source.chapters.indices.contains(place.chapter) {
            show(chapter: place.chapter, progress: place.progress)
        } else {
            show(chapter: 0)
        }
    }

    /// Opens a chapter, at its first page or its last.
    func show(chapter index: Int, atEnd: Bool = false, progress: Double = 0) {
        guard let source, source.chapters.indices.contains(index), let webView,
              let url = BookPage.url(for: source.chapters[index].path)
        else { return }
        chapter = index
        openAtEnd = atEnd
        openProgress = progress
        isSetUp = false
        textLength = nil
        // What's marked stays wanted: it's marked again once the chapter is set out.
        webView.load(URLRequest(url: url))
    }

    /// Turns a page, going on to the next or last chapter at either end.
    func turn(_ by: Int) async {
        isFollowing = false
        let turned = await call("return totalityBook.turn(by)", ["by": by]) as? Bool
        if turned == false { goPast(next: by > 0) }
    }

    private func goPast(next: Bool) {
        let target = chapter + (next ? 1 : -1)
        guard chapters.indices.contains(target) else { return }
        show(chapter: target, atEnd: !next)
    }

    /// Marks what Listen is saying, and turns to it while following, opening its chapter if need be.
    func mark(_ highlight: ReadAlongHighlight?) {
        shown = highlight
        guard let highlight else {
            Task { _ = await call("totalityBook.clear()", [:]) }
            return
        }
        if isFollowing, let source, let wanted = source.chapter(at: highlight.range.lowerBound), wanted != chapter {
            show(chapter: wanted)
            return
        }
        guard isSetUp else { return }
        let arguments: [String: Any] = [
            "start": highlight.range.lowerBound, "end": highlight.range.upperBound,
            "wordStart": highlight.word?.lowerBound ?? NSNull(), "wordEnd": highlight.word?.upperBound ?? NSNull(),
            "following": isFollowing,
        ]
        Task { _ = await call("return totalityBook.highlight(start, end, wordStart, wordEnd, following)", arguments) }
    }

    func follow() {
        isFollowing = true
        mark(shown)
    }

    private func setUp(atEnd: Bool) {
        guard let source, source.chapters.indices.contains(chapter), webView != nil else { return }
        let current = source.chapters[chapter]
        var options: [String: Any] = [
            "mode": scrolls ? "scroll" : "paged", "scale": BookPage.textScale, "colours": BookPage.colours,
            "pad": Int(Space.s5), "atEnd": atEnd, "progress": openProgress,
        ]
        if let listen = current.listen {
            let text = source.text.utf16
            let start = text.index(text.startIndex, offsetBy: listen.lowerBound, limitedBy: text.endIndex) ?? text.endIndex
            let end = text.index(text.startIndex, offsetBy: listen.upperBound, limitedBy: text.endIndex) ?? text.endIndex
            options["listen"] = String(source.text[start..<end])
            options["base"] = listen.lowerBound
        }
        Task {
            guard let reply = await call("return totalityBook.setup(options)", ["options": options]) as? [String: Any] else {
                phase = .failed("This book's pages couldn't be set out.")
                return
            }
            textLength = reply["textLength"] as? Int ?? 0
            // With scripts off, WebKit leaves them out of the page, so they're counted in the file itself.
            scripts = max(reply["scripts"] as? Int ?? 0, source.scripts(in: current.path))
            update(page: reply["page"] as? Int, pages: reply["pages"] as? Int)
            openProgress = 0
            isSetUp = true
            phase = .ready
            mark(shown)
        }
    }

    private func update(page: Int?, pages: Int?) {
        guard let page, let pages, pages >= 1, (1...pages).contains(page) else { return }
        self.page = page
        self.pages = pages
        guard let source, source.chapters.indices.contains(chapter) else { return }
        let current = source.chapters[chapter]
        let progress = pages > 1 ? Double(page - 1) / Double(pages - 1) : 0
        let listen = current.listen.map { $0.lowerBound + Int(Double($0.count) * progress) }
        onPlace?(current.path, progress, listen)
    }

    private func call(_ source: String, _ arguments: [String: Any]) async -> Any? {
        guard let webView else { return nil }
        return try? await webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: BookPage.world)
    }

    fileprivate func receive(_ message: BookMessage) {
        switch message {
        case .loaded:
            setUp(atEnd: openAtEnd)
        case .page(let page, let pages):
            update(page: page, pages: pages)
        case .tap(let offset):
            isFollowing = true
            onTap?(offset)
        case .scrolled:
            isFollowing = false
        case .edge(let next):
            isFollowing = false
            goPast(next: next)
        }
    }
}

extension BookPageController: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let decision = BookPage.decide(
            url: action.request.url, isMainFrame: action.targetFrame?.isMainFrame ?? false,
            isLinkTap: action.navigationType == .linkActivated
        )
        switch decision {
        case .allow:
            // A link inside the book is a move to that chapter.
            if let path = BookPage.path(of: action.request.url), let index = source?.index(of: path), index != chapter {
                chapter = index
                isSetUp = false
                openAtEnd = false
            }
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .open(let url):
            decisionHandler(.cancel)
            onOpen?(url)
        }
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        phase = .failed("This part of the book didn't open.")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        // A cancelled load is a link that went elsewhere, not a failure.
        guard (error as? URLError)?.code != .cancelled, (error as NSError).code != 102 else { return }
        phase = .failed("This part of the book didn't open.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        show(chapter: chapter)
    }
}

/// Holds the controller weakly, because the content controller holds its handler strongly.
private final class BookRelay: NSObject, WKScriptMessageHandler {
    weak var controller: BookPageController?

    init(_ controller: BookPageController) {
        self.controller = controller
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only our own script speaks: in its own world, in the book's main frame, in this web view.
        guard let controller, message.world == BookPage.world, message.frameInfo.isMainFrame,
              message.webView === controller.webView, let parsed = BookMessage.parse(message.body)
        else { return }
        controller.receive(parsed)
    }
}

#if os(iOS)
final class BookWebView: WKWebView {}

private struct BookWebViewHost: UIViewRepresentable {
    let webView: WKWebView?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = Theme.current.bg.platformColor
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: UIView) {
        guard let webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
#else
/// The Mac's right-click menu can fetch or open things by itself, so only copying stays.
final class BookWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            let name = item.identifier?.rawValue ?? ""
            return ["Open", "Download", "Reload", "Inspect", "Share", "Search", "Speak"].contains { name.contains($0) }
        }
        super.willOpenMenu(menu, with: event)
    }
}

private struct BookWebViewHost: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        guard let webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
#endif

/// An EPUB or HTML file on its own pages, with Listen's sentence marked on them.
struct BookPagesReader: View {
    let item: ReaderItem
    let model: ReaderModel
    let readAlong: Bool

    @State private var controller = BookPageController()
    @State private var script: ListenScript?
    @State private var text: String?
    @State private var problem: String?
    @AppStorage(BookPage.scrollKey) private var scrolls = false
    @Environment(\.openURL) private var openURL

    private var highlight: ReadAlongHighlight? {
        guard readAlong, let script, let current = model.listen.current, current.id == item.id,
              current.script.fingerprint == script.fingerprint
        else { return nil }
        return script.highlight(sentence: model.listen.sentence, spoken: model.listen.spoken)
    }

    private var chapterName: String {
        let chapters = controller.chapters
        guard chapters.indices.contains(controller.chapter) else { return "" }
        if let title = chapters[controller.chapter].title { return title }
        return chapters.count > 1 ? "Part \(controller.chapter + 1) of \(chapters.count)" : ""
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if let problem {
                ReaderMessage(systemImage: "doc.questionmark", title: "This can't be shown", detail: problem)
            } else if case .failed(let reason) = controller.phase {
                ReaderMessage(systemImage: "exclamationmark.triangle", title: "The pages didn't open", detail: reason)
            } else {
                BookWebViewHost(webView: controller.webView)
                    .overlay {
                        if controller.phase == .starting {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(theme.bg.color)
                        } else if controller.textLength == 0, controller.chapters.count == 1 {
                            ReaderMessage(
                                systemImage: "doc.text.magnifyingglass", title: "Nothing to read here",
                                detail: controller.scripts > 0
                                    ? "This page is built by scripts, which the Reader doesn't run, so there's nothing to show. Plain text in the menu shows any words the file holds."
                                    : "This file has no words in it."
                            )
                            .background(theme.bg.color)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if controller.scripts > 0, let length = controller.textLength, length > 0, length < 500 {
                            note("This page uses scripts, which the Reader doesn't run, so some of it may be missing.")
                        } else if readAlong, script?.sentences.isEmpty == true {
                            note("This file has no words to follow.")
                        } else if highlight != nil, !controller.isFollowing {
                            BackToReading { controller.follow() }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { pageBar }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.color)
        .navigationTitle(item.displayTitle)
        .toolbar {
            if controller.chapters.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(Array(controller.chapters.enumerated()), id: \.offset) { index, chapter in
                            if let title = chapter.title {
                                Button(title) {
                                    controller.isFollowing = false
                                    controller.show(chapter: index)
                                }
                            }
                        }
                    } label: {
                        ToolbarGlyph(systemImage: "list.bullet").accessibilityLabel("Chapters")
                    }
                }
            }
        }
        .onChange(of: highlight) { controller.mark(highlight) }
        .onChange(of: scrolls) { controller.scrolls = scrolls }
        .task(id: readAlong && text != nil) {
            guard readAlong, script == nil, text != nil else { return }
            script = await model.readAlongScript(of: item.id)
            controller.mark(highlight)
        }
        .task {
            controller.scrolls = scrolls
            controller.onOpen = { url in openURL(url) }
            controller.onTap = { offset in
                guard let script else { return }
                Task { await model.listen(to: item.id, from: offset, on: script) }
            }
            do {
                let file = try await model.file(of: item.id)
                let text = try? await model.text(of: item.id)
                guard let source = BookSource(data: file, mime: item.mime, text: text) else {
                    problem = ReaderError.notReadable.message
                    return
                }
                self.text = source.text.isEmpty ? nil : source.text
                controller.onPlace = { path, progress, listen in
                    model.remember(.book(chapter: path, progress: progress), listen: listen, for: item.id)
                }
                await controller.start(source, at: await opening(in: source))
                // Listen is likely next, and a long book takes seconds to split. The pages show first.
                Task { await model.prepareListening(to: item.id) }
            } catch let error as ReaderError {
                problem = error.message
            } catch {
                problem = "It may have been damaged, or it may belong to another key."
            }
        }
    }

    /// Where the person stopped, or Listen's place when Read along is on and Listen got further.
    private func opening(in source: BookSource) async -> (chapter: Int, progress: Double)? {
        switch await model.opening(of: item) {
        case .spot(.book(let path, let progress)):
            return source.index(of: path).map { ($0, progress) }
        case .listen(let offset):
            return source.place(of: offset)
        default:
            return nil
        }
    }

    private func note(_ words: String) -> some View {
        Text(words)
            .font(Typeface.callout)
            .foregroundStyle(Theme.current.textSecondary.color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .neumorphic(.raised, in: Capsule())
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s3)
    }

    /// Where the person is in the book, and buttons to turn the page.
    private var pageBar: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            ToolbarIcon("Previous page", systemImage: "chevron.left") { Task { await controller.turn(-1) } }
                .disabled(controller.phase != .ready || (controller.chapter == 0 && controller.page <= 1))
            VStack(spacing: 0) {
                if !chapterName.isEmpty {
                    Text(chapterName)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                }
                Text(scrolls ? "About \(controller.page) of \(controller.pages)" : "Page \(controller.page) of \(controller.pages)")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            ToolbarIcon("Next page", systemImage: "chevron.right") { Task { await controller.turn(1) } }
                .disabled(controller.phase != .ready || (controller.chapter == controller.chapters.count - 1 && controller.page >= controller.pages))
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .background(theme.bg.color)
    }
}
