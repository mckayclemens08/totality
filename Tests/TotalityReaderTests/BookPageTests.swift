import Foundation
import Network
import Testing
import TotalityCore
#if os(macOS)
import AppKit
import SwiftUI
import TotalityUI
import WebKit
#endif
@testable import TotalityReader

// MARK: Real words to read

/// Pride and Prejudice (1813, public domain), set out the way a Project Gutenberg EPUB sets it out: its
/// own stylesheet, a cover image, chapters as XHTML files, a page number Listen doesn't read, and the kind
/// of things a hostile copy might add: a script, a remote image and a remote stylesheet.
enum GutenbergBook {
    static let chapterOne = """
    <?xml version="1.0" encoding="utf-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>Pride and Prejudice | CHAPTER I.</title>
    <link rel="stylesheet" type="text/css" href="../styles/pg.css"/>
    <link rel="stylesheet" type="text/css" href="http://127.0.0.1:PORT/remote.css"/>
    <script>document.title = "ran"; document.body.setAttribute("data-ran", "yes");</script>
    </head><body>
    <div class="chapter"><h2><a id="CHAPTER_I"></a>CHAPTER I.</h2>
    <p class="pfirst">It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.</p>
    <p>However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered as the rightful property of some one or other of their daughters.</p>
    <p><span class="pagenum"><a id="Page_2">[Pg 2]</a></span></p>
    <p>&#8220;My dear Mr. Bennet,&#8221; said his lady to him one day, &#8220;have you heard that Netherfield Park is let at last?&#8221;</p>
    <p>Mr. Bennet replied that he had not.</p>
    <p><img src="../images/cover.png" alt="A drawing of Longbourn" onerror="document.title='ran'"/></p>
    <p><img src="http://127.0.0.1:PORT/tracker.png" alt=""/></p>
    <p>See the <a href="ch1.xhtml">next chapter</a>, or <a href="https://www.gutenberg.org/ebooks/1342">the book at Project Gutenberg</a>.</p>
    </div></body></html>
    """

    static let chapterTwo = """
    <?xml version="1.0" encoding="utf-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>CHAPTER II.</title>
    <link rel="stylesheet" type="text/css" href="../styles/pg.css"/></head><body>
    <div class="chapter"><h2><a id="CHAPTER_II"></a>CHAPTER II.</h2>
    <p class="pfirst">Mr. Bennet was among the earliest of those who waited on Mr. Bingley. He had always intended to visit him, though to the last always assuring his wife that he should not go; and till the evening after the visit was paid she had no knowledge of it.</p>
    <p>It was then disclosed in the following manner. Observing his second daughter employed in trimming a hat, he suddenly addressed her with,</p>
    <p>&#8220;I hope Mr. Bingley will like it, Lizzy.&#8221;</p>
    </div></body></html>
    """

    static let stylesheet = """
    body { font-family: Georgia, serif; line-height: 1.5; }
    h2 { text-align: center; font-variant: small-caps; }
    .pagenum { float: right; color: #767676; font-size: 0.8em; }
    @font-face { font-family: remote; src: url(http://127.0.0.1:PORT/font.woff2); }
    p.pfirst { background: url(http://127.0.0.1:PORT/background.png); }
    """

    /// The EPUB, with `PORT` pointing at a test's own server so any request that gets out is seen.
    static func epub(port: UInt16 = 9, image: Data = pixel) -> Data {
        let package = """
        <?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Pride and Prejudice</dc:title>
        <dc:creator>Jane Austen</dc:creator></metadata>
        <manifest><item id="css" href="styles/pg.css" media-type="text/css"/>
        <item id="cover" href="images/cover.png" media-type="image/png"/>
        <item id="c1" href="text/ch0.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="js" href="text/run.js" media-type="application/javascript"/></manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
        """
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8))
        zip.add("META-INF/container.xml", Data(#"<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#.utf8))
        zip.add("OEBPS/content.opf", Data(package.utf8))
        zip.add("OEBPS/styles/pg.css", Data(stylesheet.replacingOccurrences(of: "PORT", with: String(port)).utf8))
        zip.add("OEBPS/images/cover.png", image)
        zip.add("OEBPS/text/ch0.xhtml", Data(chapterOne.replacingOccurrences(of: "PORT", with: String(port)).utf8))
        zip.add("OEBPS/text/ch1.xhtml", Data(chapterTwo.utf8))
        zip.add("OEBPS/text/run.js", Data("document.title = 'ran'".utf8))
        return zip.finished()
    }

    /// One grey pixel.
    static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

/// A saved article, as a browser's "Save page" leaves it: scripts, a remote font, a form, and the words.
enum SavedArticle {
    static func html(port: UInt16 = 9) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Why teachers leave rural schools</title>
        <link rel="stylesheet" href="http://127.0.0.1:\(port)/site.css">
        <style>@font-face { font-family: x; src: url(http://127.0.0.1:\(port)/f.woff2) } body { font: 18px/1.6 Georgia }</style>
        <script src="http://127.0.0.1:\(port)/analytics.js"></script>
        <script>fetch("http://127.0.0.1:\(port)/beacon"); document.title = "ran";</script>
        </head><body>
        <nav><a href="/">Home</a> | <a href="/news">News</a></nav>
        <article><h1>Why teachers leave rural schools</h1>
        <p>Turnover is less about pay than about how a school is run. Teachers who leave name the principal before the salary &mdash; and the drive to town comes next.
        <p>Districts that kept their staff asked teachers first, before a schedule changed.
        <img src="http://127.0.0.1:\(port)/photo.jpg" alt="A school bus on a gravel road">
        <iframe src="http://127.0.0.1:\(port)/ad.html"></iframe>
        <form action="http://127.0.0.1:\(port)/subscribe"><input name="email"></form>
        </article>
        <noscript>Turn on scripts for comments.</noscript>
        </body></html>
        """
    }
}

// MARK: Reading the words

@Suite struct HTMLTextTests {
    @Test("A saved article reads as its words, without its scripts, styles, menus or markup")
    func article() {
        let read = HTMLText.read(Data(SavedArticle.html().utf8))
        #expect(read.title == "Why teachers leave rural schools")
        #expect(read.document.sections.first?.blocks.map(\.text) == [
            "Why teachers leave rural schools",
            "Turnover is less about pay than about how a school is run. Teachers who leave name the principal before the salary \u{2014} and the drive to town comes next.",
            "Districts that kept their staff asked teachers first, before a schedule changed.",
        ])
        #expect(read.document.sections.first?.blocks.first?.isHeading == true)
        let text = read.document.plainText
        for hidden in ["fetch", "font-face", "Home", "comments", "<", "analytics"] {
            #expect(!text.contains(hidden), "\(hidden)")
        }
    }

    @Test("Entities, numbered characters and broken markup still give the words")
    func forgiving() {
        let read = HTMLText.read(Data("""
        <p title="a > b">Caf&eacute; &amp; bar &#8212; &#x1F600; &bogus; &#0; done<p>Second<br>line <!-- a comment <p>not this --> end
        <script>if (a < b) { x = "</p>" }</script><p>Last <b>bold</b>
        """.utf8))
        #expect(read.document.plainText == "Café & bar \u{2014} \u{1F600} &bogus; &#0; done\nSecond\nline end\nLast bold")
        #expect(HTMLText.read(Data()).document.plainText.isEmpty)
        #expect(HTMLText.read(Data("<html><body><script>document.write('hi')</script></body></html>".utf8)).document.plainText.isEmpty)
    }

    @Test("Listen and search read an HTML file's words, never its markup")
    func readable() throws {
        let text = try ReadableText.extract(Data(SavedArticle.html().utf8), mime: "text/html")
        #expect(text.hasPrefix("Why teachers leave rural schools\nTurnover is less about pay"))
        #expect(!text.contains("<"))
        #expect(ReadableText.mime(forFilename: "article.html") == "text/html")
        #expect(ReadableText.mime(forFilename: "article.htm") == "text/html")
        #expect(BookPage.opens("text/html") && BookPage.opens(ReadableText.epubMime) && !BookPage.opens("application/pdf") && !BookPage.opens(nil))
    }
}

@MainActor
@Suite struct BookSourceTests {
    @Test("Each chapter knows where its words sit in what Listen reads")
    func chapters() throws {
        let data = GutenbergBook.epub()
        let text = try ReadableText.extract(data, mime: ReadableText.epubMime)
        let source = try #require(BookSource(data: data, mime: ReadableText.epubMime, text: text))
        #expect(source.chapters.map(\.path) == ["OEBPS/text/ch0.xhtml", "OEBPS/text/ch1.xhtml"])
        #expect(source.chapters.map(\.title) == ["CHAPTER I.", "CHAPTER II."])
        let words = text as NSString
        let first = try #require(source.chapters[0].listen)
        let second = try #require(source.chapters[1].listen)
        #expect(words.substring(with: NSRange(location: first.lowerBound, length: first.count)).hasPrefix("CHAPTER I.\nIt is a truth"))
        #expect(words.substring(with: NSRange(location: second.lowerBound, length: second.count)) ==
            "CHAPTER II.\nMr. Bennet was among the earliest of those who waited on Mr. Bingley. He had always intended to visit him, though to the last always assuring his wife that he should not go; and till the evening after the visit was paid she had no knowledge of it.\nIt was then disclosed in the following manner. Observing his second daughter employed in trimming a hat, he suddenly addressed her with,\n\u{201C}I hope Mr. Bingley will like it, Lizzy.\u{201D}")
        #expect(source.chapter(at: second.lowerBound + 5) == 1)
        #expect(source.chapter(at: 0) == 0)
        // If Listen read something else, its places would be wrong, so there are none.
        let other = try #require(BookSource(data: data, mime: ReadableText.epubMime, text: "Other words"))
        #expect(other.chapters.allSatisfy { $0.listen == nil })
    }

    @Test("Only the book's own parts are served, and nothing outside it")
    func parts() throws {
        let source = try #require(BookSource(data: GutenbergBook.epub(), mime: ReadableText.epubMime, text: nil))
        #expect(source.part("OEBPS/text/ch0.xhtml")?.type == "application/xhtml+xml")
        #expect(source.part("OEBPS/styles/pg.css")?.type == "text/css")
        #expect(source.part("OEBPS/images/cover.png")?.data == GutenbergBook.pixel)
        #expect(source.part("OEBPS/text/run.js") == nil)
        #expect(source.part("../../etc/passwd") == nil)
        #expect(source.part("OEBPS/text/../../META-INF/container.xml") == nil)
        #expect(source.part("META-INF/container.xml") == nil)

        let page = try #require(BookSource(data: Data(SavedArticle.html().utf8), mime: "text/html", text: nil))
        #expect(page.part(BookSource.page)?.type == "text/html")
        #expect(page.part("photo.jpg") == nil)
        #expect(BookSource(data: Data("not a zip".utf8), mime: ReadableText.epubMime, text: nil) == nil)
        #expect(BookSource(data: Data(), mime: "application/pdf", text: nil) == nil)
    }

    @Test("Only the book's own parts load, a tapped web link leaves for Web, and nothing else goes anywhere")
    func navigation() throws {
        let chapter = try #require(BookPage.url(for: "OEBPS/text/ch0.xhtml"))
        #expect(chapter.absoluteString == "totality-book://book/OEBPS/text/ch0.xhtml")
        #expect(BookPage.decide(url: chapter, isMainFrame: true, isLinkTap: false) == .allow)
        #expect(BookPage.decide(url: chapter, isMainFrame: true, isLinkTap: true) == .allow)
        #expect(BookPage.decide(url: chapter, isMainFrame: false, isLinkTap: false) == .cancel)
        let web = try #require(URL(string: "https://www.gutenberg.org/ebooks/1342"))
        #expect(BookPage.decide(url: web, isMainFrame: true, isLinkTap: true) == .open(web))
        #expect(BookPage.decide(url: web, isMainFrame: true, isLinkTap: false) == .cancel)
        #expect(BookPage.decide(url: web, isMainFrame: false, isLinkTap: true) == .cancel)
        for address in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "totality-book://elsewhere/x"] {
            #expect(BookPage.decide(url: URL(string: address), isMainFrame: true, isLinkTap: true) == .cancel, "\(address)")
        }
        #expect(BookPage.path(of: URL(string: "totality-book://book/")) == nil)
    }

    @Test("The read-along script's messages are read strictly")
    func messages() {
        #expect(BookMessage.parse(["type": "loaded"]) == .loaded)
        #expect(BookMessage.parse(["type": "page", "page": 2, "pages": 9]) == .page(page: 2, pages: 9))
        #expect(BookMessage.parse(["type": "page", "page": 10, "pages": 9]) == nil)
        #expect(BookMessage.parse(["type": "tap", "offset": 412]) == .tap(offset: 412))
        #expect(BookMessage.parse(["type": "tap", "offset": -1]) == nil)
        #expect(BookMessage.parse(["type": "edge", "direction": "next"]) == .edge(next: true))
        #expect(BookMessage.parse(["type": "edge", "direction": "up"]) == nil)
        #expect(BookMessage.parse(["type": "open", "url": "https://example.com"]) == nil)
        #expect(BookMessage.parse("loaded") == nil)
    }
}

@Suite struct BookTwoUserTests {
    @Test("User 2 can't open user 1's book, so there are no pages to show")
    func staysPrivate() async throws {
        let store = MemoryBlobStore()
        let user1 = try newVault(store: store)
        let book = try await user1.importFile(GutenbergBook.epub(), filename: "pride-and-prejudice.epub")
        #expect(try await user1.text(of: book.id).contains("truth universally acknowledged"))
        let user2 = try newVault(store: store)
        await #expect(throws: (any Error).self) { try await user2.body(of: book.id) }
        await #expect(throws: (any Error).self) { try await user2.text(of: book.id) }
    }
}

// MARK: The real page

#if os(macOS)
/// Counts every connection made to it, so a test can show that none were.
private final class Tripwire: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            lock.lock()
            count += 1
            lock.unlock()
            connection.cancel()
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var connections: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func stop() { listener.cancel() }
}

@MainActor
@Suite(.serialized) struct BookPageWebTests {
    private func open(_ data: Data, mime: String, text: String?) async throws -> BookPageController {
        let rules = WritingRules(directory: FileManager.default.temporaryDirectory.appendingPathComponent("BookRules-\(UUID())"), identifier: "book", rules: BookPage.rules)
        let controller = BookPageController(rules: rules)
        let source = try #require(BookSource(data: data, mime: mime, text: text))
        await controller.start(source)
        try #require(controller.webView).frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        for _ in 0..<200 where controller.phase != .ready {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(controller.phase == .ready)
        return controller
    }

    private func inWorld(_ controller: BookPageController, _ source: String) async throws -> Any? {
        try await #require(controller.webView).callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: BookPage.world)
    }

    private func inPage(_ controller: BookPageController, _ source: String) async throws -> Any? {
        try await #require(controller.webView).callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test("A sentence Listen speaks is marked on the book's page, and a tap there finds it again")
    func readAlong() async throws {
        let data = GutenbergBook.epub()
        let text = try ReadableText.extract(data, mime: ReadableText.epubMime)
        let controller = try await open(data, mime: ReadableText.epubMime, text: text)
        let script = ListenScript(text: text)
        let index = try #require(script.sentences.firstIndex { $0.text.hasPrefix("“My dear Mr. Bennet") })
        controller.mark(script.highlight(sentence: index, spoken: 3))
        try await Task.sleep(for: .milliseconds(300))
        let marked = try await inWorld(controller, "return [...CSS.highlights.get('tl-sentence')][0].toString()") as? String
        #expect(marked == "\u{201C}My dear Mr. Bennet,\u{201D} said his lady to him one day, \u{201C}have you heard that Netherfield Park is let at last?\u{201D}")
        let word = try await inWorld(controller, "return [...CSS.highlights.get('tl-word')][0].toString()") as? String
        #expect(word == "\u{201C}My")

        var tapped: [Int] = []
        controller.onTap = { tapped.append($0) }
        _ = try await inWorld(controller, """
        const range = [...CSS.highlights.get('tl-sentence')][0];
        const word = document.createRange();
        word.setStart(range.startContainer, range.startOffset + 20);
        word.setEnd(range.startContainer, range.startOffset + 21);
        const box = word.getBoundingClientRect();
        document.elementFromPoint(box.left + 1, box.top + 2).dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: box.left + 1, clientY: box.top + 2 }));
        """)
        for _ in 0..<40 where tapped.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        let offset = try #require(tapped.first)
        #expect(script.index(at: offset) == index)
    }

    @Test("Following Listen into the next chapter opens it and marks the sentence there")
    func nextChapter() async throws {
        let data = GutenbergBook.epub()
        let text = try ReadableText.extract(data, mime: ReadableText.epubMime)
        let controller = try await open(data, mime: ReadableText.epubMime, text: text)
        let script = ListenScript(text: text)
        let index = try #require(script.sentences.firstIndex { $0.text.hasPrefix("It was then disclosed") })
        controller.mark(script.highlight(sentence: index, spoken: 0))
        for _ in 0..<200 where controller.chapter != 1 || controller.phase != .ready {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.chapter == 1)
        let marked = try await inWorld(controller, "return [...CSS.highlights.get('tl-sentence')][0].toString()") as? String
        #expect(marked == "It was then disclosed in the following manner.")
    }

    @Test("The book's own scripts don't run, and its page can't see the read-along script")
    func noScripts() async throws {
        let controller = try await open(GutenbergBook.epub(), mime: ReadableText.epubMime, text: nil)
        let title = try await inWorld(controller, "return document.title") as? String
        #expect(title == "Pride and Prejudice | CHAPTER I.")
        let ran = try await inWorld(controller, "return document.body.getAttribute('data-ran')")
        #expect(ran == nil || ran is NSNull)
        // The page's own world has no read-along script, and no way to reach Swift.
        let seen = try? await inPage(controller, "return typeof totalityBook")
        #expect(seen as? String != "object")
        let handler = try? await inPage(controller, "return typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.book)")
        #expect(handler as? String != "object")
    }

    @Test("No request leaves the page: remote images, styles, fonts, scripts, frames and forms are all stopped")
    func noNetwork() async throws {
        let wire = try Tripwire()
        defer { wire.stop() }
        #expect(wire.port != 0)
        let book = try await open(GutenbergBook.epub(port: wire.port), mime: ReadableText.epubMime, text: nil)
        let article = try await open(Data(SavedArticle.html(port: wire.port).utf8), mime: "text/html", text: nil)
        try await Task.sleep(for: .seconds(2))
        #expect(wire.connections == 0)

        // The wire does catch a web view that isn't shut in, so the zero above means something.
        let open = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: WKWebViewConfiguration())
        open.loadHTMLString(#"<img src="http://127.0.0.1:\#(wire.port)/control.png">"#, baseURL: nil)
        for _ in 0..<200 where wire.connections == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(wire.connections > 0)
        // The book's own image did load, from memory.
        let width = try await inWorld(book, "return document.querySelector('img').naturalWidth") as? Int
        #expect(width == 1)
        #expect(article.textLength ?? 0 > 0)
    }

    @Test("A saved article lines up with what Listen reads, and its scripts say so")
    func article() async throws {
        let data = Data(SavedArticle.html().utf8)
        let text = try ReadableText.extract(data, mime: "text/html")
        let controller = try await open(data, mime: "text/html", text: text)
        #expect(controller.scripts == 2)
        let script = ListenScript(text: text)
        let index = try #require(script.sentences.firstIndex { $0.text.hasPrefix("Districts that kept") })
        controller.mark(script.highlight(sentence: index, spoken: 0))
        try await Task.sleep(for: .milliseconds(300))
        let marked = try await inWorld(controller, "return [...CSS.highlights.get('tl-sentence')][0].toString()") as? String
        #expect(marked == "Districts that kept their staff asked teachers first, before a schedule changed.")
    }

    @Test("A page with no words says there's nothing to read")
    func empty() async throws {
        let controller = try await open(Data("<html><body><script>document.write('Built by a script')</script></body></html>".utf8), mime: "text/html", text: nil)
        #expect(controller.textLength == 0)
        #expect(controller.scripts == 1)
    }

    @Test("Pages turn, and the last page of a chapter turns into the next")
    func turning() async throws {
        let controller = try await open(GutenbergBook.epub(), mime: ReadableText.epubMime, text: nil)
        try #require(controller.webView).frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        controller.scrolls = false
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.pages > 1)
        for _ in 0..<controller.pages {
            await controller.turn(1)
            try await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<100 where controller.chapter != 1 || controller.phase != .ready {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(controller.chapter == 1)
        #expect(controller.page == 1)
    }

    /// Writes the pages to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set.
    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let data = GutenbergBook.epub()
        let text = try ReadableText.extract(data, mime: ReadableText.epubMime)
        let controller = try await open(data, mime: ReadableText.epubMime, text: text)
        let script = ListenScript(text: text)
        let index = try #require(script.sentences.firstIndex { $0.text.hasPrefix("“My dear Mr. Bennet") })
        controller.mark(script.highlight(sentence: index, spoken: 12))
        try await Task.sleep(for: .milliseconds(500))
        let configuration = WKSnapshotConfiguration()
        let webView = try #require(controller.webView)
        configuration.rect = webView.bounds
        let image = try await webView.takeSnapshot(configuration: configuration)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("book-epub-read-along.png"))

        // The states around the pages.
        let states = VStack(spacing: Space.s5) {
            ProgressView()
            ReaderMessage(systemImage: "doc.questionmark", title: "This can't be shown", detail: ReaderError.notReadable.message)
            ReaderMessage(
                systemImage: "doc.text.magnifyingglass", title: "Nothing to read here",
                detail: "This page is built by scripts, which the Reader doesn't run, so there's nothing to show. Plain text in the menu shows any words the file holds."
            )
            Text("This page uses scripts, which the Reader doesn't run, so some of it may be missing.")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textSecondary.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .neumorphic(.raised, in: Capsule())
                .padding(.horizontal, Space.s4)
        }
        .padding(.top, Space.s4)
        .frame(width: 393, height: 760)
        .background(Theme.current.bg.color)
        let renderer = ImageRenderer(content: states)
        renderer.scale = 2
        let stateImage = try #require(renderer.nsImage?.tiffRepresentation)
        let statePNG = try #require(NSBitmapImageRep(data: stateImage)?.representation(using: .png, properties: [:]))
        try statePNG.write(to: URL(fileURLWithPath: directory).appendingPathComponent("book-states.png"))
    }
}
#endif
