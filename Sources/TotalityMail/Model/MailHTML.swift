import Foundation
import Network
import TotalityUI
import WebKit

/// A message's HTML is hostile. Nothing stands alone here, because `<link rel="preconnect">` got a
/// connection past both the page's policy and the rule list when it was tested, so a sender could see
/// when and where a message was opened. Scripts are off in the web view. `<link>` elements are taken out
/// before the page loads. The page carries a policy that refuses every load, a compiled rule list refuses
/// the same loads, and every navigation is cancelled. While images are off, the web view's only way out
/// is a proxy that isn't there, so whatever else WebKit might try goes nowhere.
enum MailHTML {
    /// Remote images are the only thing the person can turn on, and only over HTTPS.
    static func policy(allowingImages: Bool) -> String {
        let images = allowingImages ? "data: https:" : "data:"
        return "default-src 'none'; img-src \(images); style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
    }

    /// Renames every `<link>`, which mail has no use for, so the browser sees an element that means
    /// nothing. A tag's name ends at a space, a slash, or a `>`, so nothing can hide from this, and
    /// matching inside a comment or some text only changes how that text reads.
    static func withoutLinks(_ html: String) -> String {
        html.replacing(/(?i)<link(?=[\s\/>])/, with: "<x-link")
    }

    /// The message goes last, so the policy is in force before a byte of it is read.
    static func document(_ html: String, allowingImages: Bool) -> String {
        let theme = Theme.current
        return """
        <!doctype html><meta http-equiv="Content-Security-Policy" content="\(policy(allowingImages: allowingImages))">\
        <meta http-equiv="x-dns-prefetch-control" content="off">\
        <meta name="viewport" content="width=device-width, initial-scale=1">\
        <meta name="color-scheme" content="light">\
        <style>html{background:\(css(theme.surface));color:\(css(theme.textPrimary));font:-apple-system-body;-webkit-text-size-adjust:100%}\
        body{margin:0;overflow-wrap:anywhere}img{max-width:100%;height:auto}</style>
        """ + withoutLinks(html)
    }

    private static func css(_ token: ColorToken) -> String {
        "#" + String(token.hex, radix: 16).leftPadded(to: 6)
    }

    /// Only worth asking about if the message has any. This may be wrong in the safe direction: an extra
    /// question, never a load.
    static func hasRemoteImages(_ html: String) -> Bool {
        html.contains(/(?i)(src|srcset|background)\s*=\s*["']?\s*(https?:)?\/\/|url\(\s*["']?\s*(https?:)?\/\//)
    }

    /// Blocks everything, including what the page's own policy would miss.
    static let closedRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    /// The same, with one way through.
    static let imageRules = #"""
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},\#
    {"trigger":{"url-filter":"^https://","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}]
    """#

    enum Navigation: Equatable {
        case stay, refuse
        case open(URL)
    }

    /// The first load is the only one a page gets. A tap on a web link leaves for Web. Everything else
    /// a page might try, like a redirect or a form, simply doesn't happen.
    static func navigation(to url: URL?, isLinkTap: Bool) -> Navigation {
        guard let url else { return .refuse }
        if isLinkTap {
            let scheme = url.scheme?.lowercased()
            return scheme == "https" || scheme == "http" ? .open(url) : .refuse
        }
        return url.absoluteString == "about:blank" ? .stay : .refuse
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}

/// The compiled rule lists. They live in their own store, because Web's blocker clears out the shared
/// one. No list means no page: the screen shows the message's plain text instead.
@MainActor
public final class MailRules {
    private let store: WKContentRuleListStore?
    private var closed: WKContentRuleList?
    private var images: WKContentRuleList?

    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MailRules", isDirectory: true)) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory)
    }

    func list(allowingImages: Bool) async -> WKContentRuleList? {
        if allowingImages {
            if images == nil { images = await compile("images", MailHTML.imageRules) }
            return images
        }
        if closed == nil { closed = await compile("closed", MailHTML.closedRules) }
        return closed
    }

    private func compile(_ identifier: String, _ rules: String) async -> WKContentRuleList? {
        guard let store else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, _ in
                done.resume(returning: list)
            }
        }
    }
}

/// Makes the one kind of web view a message may appear in.
@MainActor
enum MailWebView {
    /// Nothing listens here, so a connection through it fails at once and on this device.
    private static let nowhere = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)

    static func configuration(rules: WKContentRuleList, allowingImages: Bool, proxy: NWEndpoint = nowhere) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if !allowingImages {
            configuration.websiteDataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: proxy)]
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(rules)
        return configuration
    }
}
