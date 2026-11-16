import CryptoKit
import Foundation
import Network
import TotalityUI
import WebKit

/// The writing page is a web view running the bundled CodeMirror editor (web/reader-editor). It is
/// shut in: it loads only what's bundled in the app, inline in one document; a compiled rule list and the
/// page's own policy refuse every load; its data store keeps nothing; its only way out is a proxy that
/// isn't there; and one message handler, `editor`, is the only thing it can say to Swift.
enum WritingPage {
    static let handlerName = "editor"

    /// The bundled script and stylesheet. Missing files mean a broken build, so the page doesn't start.
    static func resources(bundle: Bundle = .module) -> (script: String, style: String)? {
        guard let folder = bundle.url(forResource: "Editor", withExtension: nil),
              let script = try? String(contentsOf: folder.appendingPathComponent("editor.js"), encoding: .utf8),
              let style = try? String(contentsOf: folder.appendingPathComponent("editor.css"), encoding: .utf8)
        else { return nil }
        return (script, style)
    }

    /// Only the bundled script may run, named by its hash, so text that ever found its way into the page
    /// as markup still couldn't run anything.
    static func policy(script: String) -> String {
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        return "default-src 'none'; script-src 'sha256-\(hash)'; style-src 'unsafe-inline'; img-src data:; " +
            "font-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; worker-src 'none'; " +
            "base-uri 'none'; form-action 'none'"
    }

    /// Every value the stylesheet uses, from the design tokens.
    static func variables(theme: Theme = .current) -> String {
        let colours: [(String, ColorToken)] = [
            ("bg", theme.bg), ("surface", theme.surface), ("sunken", theme.surfaceSunken),
            ("text", theme.textPrimary), ("text2", theme.textSecondary), ("text3", theme.textTertiary),
            ("accent", theme.accent), ("highlight", theme.highlight), ("highlight-strong", theme.highlightStrong),
            ("shadow-dark", theme.shadowDark),
        ]
        let sizes: [(String, CGFloat)] = [
            ("s1", Space.s1), ("s2", Space.s2), ("s3", Space.s3), ("s4", Space.s4),
            ("gutter", Space.s4), ("hairline", Space.hairline), ("radius-sm", Radius.sm),
            // The same reading width as the Reader's other pages.
            ("width", Space.s8 * 10), ("end-space", Space.s8 * 2),
        ]
        let colourLines = colours.map { "--tl-\($0.0):\(css($0.1))" }
        let sizeLines = sizes.map { "--tl-\($0.0):\(Int($0.1))px" }
        // The type scale, shared with export.
        let number = { (value: CGFloat) in String(format: "%g", Double(value)) }
        var typeLines = [
            "--tl-body-scale:\(number(WritingType.bodyScale))", "--tl-line:\(number(WritingType.lineHeight))",
            "--tl-heading-line:\(number(WritingType.headingLineHeight))",
        ]
        for (index, scale) in WritingType.headingScales.enumerated() {
            typeLines.append("--tl-h\(index + 1):\(number(scale))")
            typeLines.append("--tl-h\(index + 1)-space:\(Int(WritingType.headingSpace[index]))px")
        }
        return ":root{" + (colourLines + sizeLines + typeLines).joined(separator: ";") + "}"
    }

    static func css(_ token: ColorToken) -> String {
        let hex = String(token.hex, radix: 16)
        let padded = String(repeating: "0", count: max(0, 6 - hex.count)) + hex
        return token.opacity < 1 ? "#\(padded)\(String(format: "%02x", Int((token.opacity * 255).rounded())))" : "#\(padded)"
    }

    /// The whole page in one string, policy first, so it's in force before anything else is read.
    static func document(script: String, style: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="\(policy(script: script))">\
        <meta http-equiv="x-dns-prefetch-control" content="off">\
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\
        <meta name="color-scheme" content="light">\
        <style>\(variables())\n\(style)</style></head>\
        <body><div id="editor"></div><script>\(script)</script></body></html>
        """
    }

    /// Blocks everything, including what the page's own policy would miss.
    static let closedRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    /// Nothing listens here, so a connection through it fails at once and on this device.
    private static let nowhere = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)

    @MainActor
    static func configuration(rules: WKContentRuleList, handler: any WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: nowhere)]
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(rules)
        configuration.userContentController.add(handler, contentWorld: .page, name: handlerName)
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif
        return configuration
    }

    /// The only navigation the page ever gets is its own first load. A link never navigates: the page
    /// asks Swift to open it, which checks the address.
    static func allows(url: URL?, isMainFrame: Bool, isLinkTap: Bool, expectingLoad: Bool) -> Bool {
        expectingLoad && isMainFrame && !isLinkTap && url?.absoluteString == "about:blank"
    }
}

/// What the page can say. Anything else it sends is dropped.
enum WritingMessage: Equatable {
    case ready
    /// Typing happened. The text follows after a pause.
    case changed(revision: Int)
    case text(revision: Int, text: String)
    case format(WritingFormat)
    /// The person asked to add or change a link. Carries the current address, if any.
    case link(String)
    case open(URL)
    case stats(WritingStats)
    /// The headings, the labels a cross-reference can point at, and the doc's citation style.
    case outline([WritingHeading], labels: [WritingLabel], style: WritingStyle)
    /// Command-F: the person wants the find bar.
    case find
    case matches(WritingMatches)
    /// A wiki link was followed to another doc, by its title, and maybe a heading in it.
    case wiki(target: String, heading: String)
    /// Where the person is: the cursor's place in the text, and how far down the page, from 0 to 1.
    case place(cursor: Int, scroll: Double)

    /// A doc can be as large as an imported file, and no larger.
    static let maxText = ReaderVault.maxTextBytes

    static func parse(_ body: Any) -> WritingMessage? {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready
        case "changed":
            guard let revision = message["revision"] as? Int, revision >= 0 else { return nil }
            return .changed(revision: revision)
        case "text":
            guard let revision = message["revision"] as? Int, revision >= 0,
                  let text = message["text"] as? String, text.utf8.count <= maxText
            else { return nil }
            return .text(revision: revision, text: text)
        case "format":
            guard let state = message["state"] as? [String: Any] else { return nil }
            return .format(WritingFormat(state))
        case "link":
            let url = message["url"] as? String ?? ""
            return .link(String(url.prefix(DocText.maxLinkLength)))
        case "open":
            guard let raw = message["url"] as? String, raw.count <= DocText.maxLinkLength,
                  let url = URL(string: raw), DocText.isOpenable(url)
            else { return nil }
            return .open(url)
        case "stats":
            guard let stats = message["stats"] as? [String: Any] else { return nil }
            return .stats(WritingStats(stats))
        case "outline":
            guard let headings = message["headings"] as? [[String: Any]] else { return nil }
            let labels = (message["labels"] as? [[String: Any]] ?? []).prefix(WritingHeading.limit).compactMap(WritingLabel.init)
            return .outline(
                headings.prefix(WritingHeading.limit).compactMap(WritingHeading.init), labels: Array(labels),
                style: WritingStyle(rawValue: message["style"] as? String ?? "") ?? .apa
            )
        case "find":
            return .find
        case "matches":
            return .matches(WritingMatches(message))
        case "wiki":
            let heading = message["heading"] as? String ?? ""
            guard let target = message["target"] as? String,
                  !target.trimmingCharacters(in: .whitespaces).isEmpty,
                  target.count <= WikiLinks.maxTitle, heading.count <= WikiLinks.maxTitle,
                  !target.contains(where: { "[]|#\n".contains($0) }), !heading.contains(where: { "[]|\n".contains($0) })
            else { return nil }
            return .wiki(target: target.trimmingCharacters(in: .whitespaces), heading: heading.trimmingCharacters(in: .whitespaces))
        case "place":
            guard let cursor = message["cursor"] as? Int, (0...maxText).contains(cursor),
                  let scroll = (message["scroll"] as? NSNumber)?.doubleValue, scroll.isFinite, (0...1).contains(scroll)
            else { return nil }
            return .place(cursor: cursor, scroll: scroll)
        default:
            return nil
        }
    }
}

/// What the format bar shows as on, where the cursor is.
struct WritingFormat: Equatable {
    var bold = false
    var italic = false
    var heading = 0
    var list = ""
    var quote = false
    var link = ""

    init() {}

    init(_ state: [String: Any]) {
        bold = state["bold"] as? Bool ?? false
        italic = state["italic"] as? Bool ?? false
        heading = min(6, max(0, state["heading"] as? Int ?? 0))
        let list = state["list"] as? String ?? ""
        self.list = ["bullet", "numbered", "task"].contains(list) ? list : ""
        quote = state["quote"] as? Bool ?? false
        link = String((state["link"] as? String ?? "").prefix(DocText.maxLinkLength))
    }
}

/// Counts the page works out after each pause.
struct WritingStats: Equatable {
    var words = 0
    var selection = 0
    var section = 0
    var characters = 0

    init() {}

    init(_ values: [String: Any]) {
        let count = { (key: String) in max(0, values[key] as? Int ?? 0) }
        words = count("words")
        selection = count("selection")
        section = count("section")
        characters = count("characters")
    }
}

/// One heading in the outline, and where it starts in the text.
struct WritingHeading: Equatable, Identifiable {
    static let limit = 2000

    let level: Int
    let text: String
    let from: Int

    var id: Int { from }

    init?(_ values: [String: Any]) {
        guard let level = values["level"] as? Int, (1...6).contains(level),
              let text = values["text"] as? String, let from = values["from"] as? Int, from >= 0
        else { return nil }
        self.level = level
        self.text = String(text.prefix(200))
        self.from = from
    }

    init(level: Int, text: String, from: Int) {
        self.level = level
        self.text = text
        self.from = from
    }
}

/// A labelled section, figure or table a cross-reference can point at.
struct WritingLabel: Equatable, Identifiable {
    let id: String
    let kind: String
    let number: Int
    let caption: String

    init?(_ values: [String: Any]) {
        guard let id = values["id"] as? String, id.count <= 200,
              id.wholeMatch(of: /(sec|fig|tbl):[\w:.\-]+/) != nil,
              let kind = values["kind"] as? String, ["sec", "fig", "tbl"].contains(kind), id.hasPrefix(kind + ":")
        else { return nil }
        self.id = id
        self.kind = kind
        number = max(0, values["number"] as? Int ?? 0)
        caption = String((values["caption"] as? String ?? "").prefix(200))
    }

    init(id: String, kind: String, number: Int, caption: String) {
        self.id = id
        self.kind = kind
        self.number = number
        self.caption = caption
    }

    /// How the picker names it: "Figure 2: Turnover by district type".
    var title: String {
        switch kind {
        case "fig": "Figure \(number)" + (caption.isEmpty ? "" : ": \(caption)")
        case "tbl": "Table \(number)" + (caption.isEmpty ? "" : ": \(caption)")
        default: caption.isEmpty ? id : caption
        }
    }
}

/// The citation styles bundled with the editor. A doc names one in its front matter.
enum WritingStyle: String, CaseIterable, Identifiable {
    case apa, mla, chicago

    var id: String { rawValue }

    var name: String {
        switch self {
        case .apa: "APA"
        case .mla: "MLA"
        case .chicago: "Chicago"
        }
    }
}

/// How many matches find has, and which one is selected (0 when none is).
struct WritingMatches: Equatable {
    var count = 0
    var current = 0

    init(count: Int = 0, current: Int = 0) {
        self.count = count
        self.current = current
    }

    init(_ values: [String: Any]) {
        count = max(0, values["count"] as? Int ?? 0)
        current = min(count, max(0, values["current"] as? Int ?? 0))
    }
}

/// The page's settings, kept on this device. They change how the page looks and behaves, never the text,
/// except smart punctuation, which changes what's typed from then on.
struct WritingSettings: Equatable {
    var focus = false
    var typewriter = false
    var smartPunctuation = true
    var serif = false

    var dictionary: [String: Bool] {
        ["focus": focus, "typewriter": typewriter, "smartPunctuation": smartPunctuation, "serif": serif]
    }
}

/// The compiled rule list lives in its own store, because Web's blocker clears out the shared one.
@MainActor
final class WritingRules {
    static let shared = WritingRules()

    private let store: WKContentRuleListStore?
    private var closed: WKContentRuleList?
    private let identifier: String
    private let rules: String

    init(
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("WritingRules", isDirectory: true),
        identifier: String = "closed", rules: String = WritingPage.closedRules
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)
        self.identifier = identifier
        self.rules = rules
    }

    /// No list means no page.
    func list() async -> WKContentRuleList? {
        if let closed { return closed }
        guard let store else { return nil }
        closed = await withCheckedContinuation { (done: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, _ in
                done.resume(returning: list)
            }
        }
        return closed
    }
}
