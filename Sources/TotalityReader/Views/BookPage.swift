import Foundation
import Network
import TotalityUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// An EPUB or HTML file, shown as it was made, in a web view as shut in as the writing page. The book's own
/// scripts never run, every network request is blocked, nothing is kept, and the file's parts come from
/// memory through `totality-book:` and nowhere else. Read along is our own script, in a content world
/// the book can't see, and it's the only thing that can talk to Swift.
enum BookPage {
    static let scheme = "totality-book"
    static let host = "book"
    static let handlerName = "book"
    static let plainTextKey = "reader.plainText"
    static let scrollKey = "reader.book.scroll"

    /// Read along lives here, out of the book's sight.
    @MainActor static let world = WKContentWorld.world(name: "TotalityBook")

    /// The file kinds that open as their own pages.
    static func opens(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime == ReadableText.epubMime || HTMLText.mimes.contains(mime)
    }

    /// The bundled read-along script. Missing means a broken build, so the pages don't open.
    static func script(bundle: Bundle = .module) -> String? {
        guard let folder = bundle.url(forResource: "Editor", withExtension: nil) else { return nil }
        return try? String(contentsOf: folder.appendingPathComponent("book.js"), encoding: .utf8)
    }

    /// Sent with every part of the book, so even a part that tries can't run a script or reach out.
    static let policy = "default-src 'none'; script-src 'none'; img-src \(scheme): data:; style-src \(scheme): 'unsafe-inline'; " +
        "font-src \(scheme): data:; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; " +
        "child-src 'none'; worker-src 'none'; manifest-src 'none'; form-action 'none'; base-uri 'none'"

    /// Everything is blocked but the book's own parts.
    static let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},"# +
        #"{"trigger":{"url-filter":"^totality-book://book/"},"action":{"type":"ignore-previous-rules"}}]"#

    @MainActor static let sharedRules = WritingRules(identifier: "book", rules: rules)

    private static let nowhere = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)

    static func url(for path: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.path = "/" + path
        return parts.url
    }

    /// The part of the book a URL names, or nil when it isn't one of ours.
    static func path(of url: URL?) -> String? {
        guard let url, url.scheme == scheme, url.host == host else { return nil }
        let path = url.path.drop { $0 == "/" }
        return path.isEmpty ? nil : String(path)
    }

    @MainActor
    static func configuration(rules: WKContentRuleList, handler: any WKScriptMessageHandler, files: any WKURLSchemeHandler, script: String) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: nowhere)]
        // The book's own scripts never run. Ours is injected by the app, which this doesn't stop.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.setURLSchemeHandler(files, forURLScheme: scheme)
        configuration.userContentController.add(rules)
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world
        ))
        configuration.userContentController.add(handler, contentWorld: world, name: handlerName)
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif
        return configuration
    }

    enum Decision: Equatable {
        case allow
        case cancel
        /// A link out of the book, which goes to the Web module after the person's tap.
        case open(URL)
    }

    /// The book's own parts can load in the main frame. A tapped link to the web leaves the book; nothing
    /// else loads, and no frame inside the page loads anything.
    static func decide(url: URL?, isMainFrame: Bool, isLinkTap: Bool) -> Decision {
        if path(of: url) != nil { return isMainFrame ? .allow : .cancel }
        if isLinkTap, isMainFrame, let url, DocText.isOpenable(url) { return .open(url) }
        return .cancel
    }

    /// The text size the Reader uses, as a multiple of the usual size.
    @MainActor static var textScale: Double {
        #if canImport(UIKit)
        Double(UIFontMetrics.default.scaledValue(for: 17) / 17)
        #else
        1
        #endif
    }

    static var colours: [String: String] {
        let theme = Theme.current
        return [
            "bg": WritingPage.css(theme.bg), "highlight": WritingPage.css(theme.highlight),
            "highlightStrong": WritingPage.css(theme.highlightStrong),
        ]
    }
}

/// An open book's parts, served from memory. The file was opened from its sealed copy and never touches
/// the disk. A name only ever looks something up in the archive, so `../` can't reach anything else.
@MainActor
final class BookSource {
    struct Chapter: Equatable {
        let path: String
        let title: String?
        /// Where this chapter's words sit in what Listen reads. Nil for a chapter with none.
        let listen: Range<Int>?
    }

    enum Kind { case epub, html }

    let kind: Kind
    let chapters: [Chapter]
    /// Listen's text, which the chapter ranges point into.
    let text: String
    private var archive: ZipArchive?
    private let html: Data?
    private let types: [String: String]
    private var cache: [String: Data] = [:]
    private var cachedBytes = 0
    private static let maxCache = 64 * 1024 * 1024
    static let page = "page.html"

    /// The parts of an EPUB that may be shown. Audio, video and scripts aren't among them.
    private static let shown: [String: String] = [
        "xhtml": "application/xhtml+xml", "html": "text/html", "htm": "text/html", "css": "text/css",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "otf": "font/otf", "ttf": "font/ttf", "woff": "font/woff", "woff2": "font/woff2",
    ]

    /// Nil when the file can't be opened as pages.
    init?(data: Data, mime: String?, text: String?) {
        if mime == ReadableText.epubMime {
            guard var archive = try? ZipArchive(data), let package = try? BookReader.package(&archive), !package.spine.isEmpty else { return nil }
            kind = .epub
            types = package.types
            html = nil
            self.archive = archive
            let document = (try? BookReader.epub(data))?.document
            // Listen reads the book's text. Each chapter's part of it is found from the same reading.
            var places: [String: Range<Int>] = [:]
            var titles: [String: String] = [:]
            var start = 0
            for section in document?.sections ?? [] {
                let length = section.blocks.map(\.text).joined(separator: "\n").utf16.count
                if let source = section.source {
                    places[source] = start..<(start + length)
                    titles[source] = section.title
                }
                start += length + 1
            }
            let whole = document?.plainText ?? ""
            // If what Listen reads isn't this reading, its places would be wrong, so there are none.
            let matches = text == nil || text == whole
            self.text = matches ? whole : ""
            chapters = package.spine.map { Chapter(path: $0, title: titles[$0], listen: matches ? places[$0] : nil) }
        } else if let mime, HTMLText.mimes.contains(mime) {
            kind = .html
            types = [:]
            html = data
            archive = nil
            let whole = HTMLText.read(data).document.plainText
            let matches = text == nil || text == whole
            self.text = matches ? whole : ""
            chapters = [Chapter(path: Self.page, title: nil, listen: matches ? 0..<whole.utf16.count : nil)]
        } else {
            return nil
        }
    }

    /// The chapter whose words hold a place in Listen's text.
    func chapter(at offset: Int) -> Int? {
        chapters.lastIndex { $0.listen.map { $0.lowerBound <= offset } ?? false }
    }

    /// The chapter, and how far through it from 0 to 1, that a place in Listen's text falls in.
    func place(of offset: Int) -> (chapter: Int, progress: Double)? {
        guard let index = chapter(at: offset), let range = chapters[index].listen else { return nil }
        return (index, range.isEmpty ? 0 : min(1, max(0, Double(offset - range.lowerBound) / Double(range.count))))
    }

    /// How many scripts a part holds. None of them run; the count only says why a page may be bare.
    func scripts(in path: String) -> Int {
        guard let data = part(path)?.data else { return 0 }
        let words = String(decoding: data, as: UTF8.self) as NSString
        var count = 0
        var from = 0
        while from < words.length {
            let found = words.range(of: "<script", options: .caseInsensitive, range: NSRange(location: from, length: words.length - from))
            guard found.location != NSNotFound else { break }
            count += 1
            from = found.location + found.length
        }
        return count
    }

    func index(of path: String) -> Int? {
        chapters.firstIndex { $0.path == path }
    }

    /// The part and its type, or nil when there's no such part, or it isn't one that's shown.
    func part(_ path: String) -> (data: Data, type: String)? {
        switch kind {
        case .html:
            guard path == Self.page, let html else { return nil }
            return (html, "text/html")
        case .epub:
            let ext = (path as NSString).pathExtension.lowercased()
            guard let type = Self.shown[ext] else { return nil }
            // The package's own word for a chapter's type wins, so an XHTML chapter reads as XHTML.
            let declared = types[path].flatMap { Self.shown.values.contains($0) ? $0 : nil }
            if let cached = cache[path] { return (cached, declared ?? type) }
            guard let data = try? archive?.read(path) else { return nil }
            if cachedBytes + data.count <= Self.maxCache {
                cache[path] = data
                cachedBytes += data.count
            }
            return (data, declared ?? type)
        }
    }
}

/// Hands the web view the book's parts. Anything that isn't one gets a plain "not found".
@MainActor
final class BookFiles: NSObject, @preconcurrency WKURLSchemeHandler {
    weak var source: BookSource?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        guard let path = BookPage.path(of: url), let part = source?.part(path),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": part.type,
                  "Content-Security-Policy": BookPage.policy,
                  "X-Content-Type-Options": "nosniff",
                  "Cache-Control": "no-store",
              ])
        else {
            let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])
            if let missing { task.didReceive(missing) }
            task.didReceive(Data())
            task.didFinish()
            return
        }
        task.didReceive(response)
        task.didReceive(part.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// What the read-along script can say. Anything else is dropped.
enum BookMessage: Equatable {
    /// The page is there and the script is running.
    case loaded
    case page(page: Int, pages: Int)
    /// A tap on words, with the place in Listen's text.
    case tap(offset: Int)
    /// The person moved the page themselves.
    case scrolled
    /// A swipe past the first or last page of a chapter.
    case edge(next: Bool)

    static func parse(_ body: Any) -> BookMessage? {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return nil }
        switch type {
        case "loaded":
            return .loaded
        case "page":
            guard let page = message["page"] as? Int, let pages = message["pages"] as? Int,
                  (1...100_000).contains(pages), (1...pages).contains(page)
            else { return nil }
            return .page(page: page, pages: pages)
        case "tap":
            guard let offset = message["offset"] as? Int, offset >= 0, offset <= ReaderVault.maxImportBytes else { return nil }
            return .tap(offset: offset)
        case "scrolled":
            return .scrolled
        case "edge":
            guard let direction = message["direction"] as? String, ["next", "previous"].contains(direction) else { return nil }
            return .edge(next: direction == "next")
        default:
            return nil
        }
    }
}
