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
            ("accent", theme.accent), ("highlight", theme.highlight), ("shadow-dark", theme.shadowDark),
        ]
        let sizes: [(String, CGFloat)] = [
            ("s1", Space.s1), ("s2", Space.s2), ("s3", Space.s3), ("s4", Space.s4),
            ("gutter", Space.s4), ("hairline", Space.hairline), ("radius-sm", Radius.sm),
            // The same reading width as the Reader's other pages.
            ("width", Space.s8 * 10), ("end-space", Space.s8 * 2),
        ]
        let colourLines = colours.map { "--tl-\($0.0):\(css($0.1))" }
        let sizeLines = sizes.map { "--tl-\($0.0):\(Int($0.1))px" }
        return ":root{" + (colourLines + sizeLines).joined(separator: ";") + "}"
    }

    private static func css(_ token: ColorToken) -> String {
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

    /// A doc can be as large as an imported file, and no larger.
    static let maxText = ReaderVault.maxImportBytes

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

/// The compiled rule list lives in its own store, because Web's blocker clears out the shared one.
@MainActor
final class WritingRules {
    static let shared = WritingRules()

    private let store: WKContentRuleListStore?
    private var closed: WKContentRuleList?

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("WritingRules", isDirectory: true)) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)
    }

    /// No list means no page.
    func list() async -> WKContentRuleList? {
        if let closed { return closed }
        guard let store else { return nil }
        closed = await withCheckedContinuation { (done: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: "closed", encodedContentRuleList: WritingPage.closedRules) { list, _ in
                done.resume(returning: list)
            }
        }
        return closed
    }
}
