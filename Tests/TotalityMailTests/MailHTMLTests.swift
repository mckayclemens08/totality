import Foundation
import Network
import Testing
import WebKit
@testable import TotalityMail

@Suite struct MailHTMLTests {
    @Test func thePolicyComesBeforeAnyOfTheMessage() throws {
        let document = MailHTML.document("<img src=https://tracker.example/open.gif>", allowingImages: false)
        let policy = try #require(document.range(of: "Content-Security-Policy"))
        let message = try #require(document.range(of: "tracker.example"))
        #expect(policy.lowerBound < message.lowerBound)
    }

    @Test func imagesAreRefusedUntilThePersonSaysSoAndThenOnlyOverHTTPS() {
        #expect(MailHTML.policy(allowingImages: false).contains("img-src data:;"))
        #expect(MailHTML.policy(allowingImages: true).contains("img-src data: https:;"))
        #expect(!MailHTML.policy(allowingImages: true).contains("http:"))
        for allowing in [false, true] {
            let policy = MailHTML.policy(allowingImages: allowing)
            #expect(policy.hasPrefix("default-src 'none'"))
            #expect(policy.contains("base-uri 'none'"))
            #expect(policy.contains("form-action 'none'"))
            #expect(!policy.contains("script"))
        }
    }

    @Test func remoteImagesAreFoundInEveryUsualPlace() {
        #expect(MailHTML.hasRemoteImages(#"<img src="https://a.example/x.png">"#))
        #expect(MailHTML.hasRemoteImages("<IMG SRC=http://a.example/x.png>"))
        #expect(MailHTML.hasRemoteImages("<img src='//a.example/x.png'>"))
        #expect(MailHTML.hasRemoteImages(#"<img srcset="https://a.example/x.png 2x">"#))
        #expect(MailHTML.hasRemoteImages(#"<td background="https://a.example/x.png">"#))
        #expect(MailHTML.hasRemoteImages("<div style=\"background:url('https://a.example/x.png')\">"))
        #expect(!MailHTML.hasRemoteImages("<p>Read more at https://a.example</p>"))
        #expect(!MailHTML.hasRemoteImages(#"<img src="data:image/png;base64,AAAA">"#))
    }

    @Test func onlyTheFirstLoadAndWebLinkTapsGoAnywhere() {
        let web = URL(string: "https://a.example/page")!
        #expect(MailHTML.navigation(to: URL(string: "about:blank"), isLinkTap: false) == .stay)
        #expect(MailHTML.navigation(to: web, isLinkTap: true) == .open(web))
        #expect(MailHTML.navigation(to: web, isLinkTap: false) == .refuse)
        #expect(MailHTML.navigation(to: URL(string: "mailto:a@b.example"), isLinkTap: true) == .refuse)
        #expect(MailHTML.navigation(to: URL(string: "javascript:alert(1)"), isLinkTap: true) == .refuse)
        #expect(MailHTML.navigation(to: URL(string: "file:///etc/passwd"), isLinkTap: true) == .refuse)
        #expect(MailHTML.navigation(to: nil, isLinkTap: true) == .refuse)
    }

    @Test func everyLinkElementLosesItsName() {
        for tag in ["<link rel=preconnect>", "<LINK rel=preconnect>", "<link\trel=preconnect>", "<link\nrel=preconnect>", "<link/rel=preconnect>", "<link>"] {
            #expect(!MailHTML.withoutLinks(tag).lowercased().contains("<link"))
        }
        #expect(MailHTML.withoutLinks("<linked>") == "<linked>")
        #expect(MailHTML.document("<link rel=preconnect>", allowingImages: true).contains("<x-link"))
    }

    @Test func bothRuleListsParse() throws {
        for rules in [MailHTML.closedRules, MailHTML.imageRules] {
            #expect(try JSONSerialization.jsonObject(with: Data(rules.utf8)) is [Any])
        }
    }

    @Test func aLinkInPlainMailIsOnlyAWebLink() {
        let linked = MailText.linked("See https://a.example/map or write to dana@usetotality.com")
        let links = linked.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://a.example/map")!])
    }
}

/// A listener on this machine that counts anything that tries to reach it.
private final class Tripwire: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var hits = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.withLock { self?.hits += 1 }
            connection.cancel()
        }
    }

    var count: Int { lock.withLock { hits } }

    func start() async throws -> NWEndpoint.Port {
        listener.start(queue: .global())
        for _ in 0..<200 {
            if let port = listener.port, port.rawValue != 0 { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    func stop() { listener.cancel() }
}

@MainActor
private final class PageWatcher: NSObject, WKNavigationDelegate {
    private var finished: CheckedContinuation<Void, Never>?
    var refused: [URL] = []

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if MailHTML.navigation(to: action.request.url, isLinkTap: action.navigationType == .linkActivated) == .stay {
            decisionHandler(.allow)
        } else {
            if let url = action.request.url { refused.append(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.resume()
        finished = nil
    }

    func waitForFinish() async {
        await withCheckedContinuation { finished = $0 }
    }
}

/// The real thing: a hostile message in the same web view the screens use, with a listener standing in
/// for the sender's server. Anything that reaches it is a leak. WebKit tears a page down with its view,
/// so a test has to keep the view for as long as it waits, or a quiet result proves nothing.
@MainActor
@Suite(.serialized) struct MailPageSafetyTests {
    private static let settle = Duration.seconds(2)

    private func load(
        _ html: String, allowingImages: Bool = false, proxy: NWEndpoint? = nil
    ) async throws -> (view: WKWebView, watcher: PageWatcher) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rules = try #require(await MailRules(directory: directory).list(allowingImages: allowingImages))
        let configuration = if let proxy {
            MailWebView.configuration(rules: rules, allowingImages: allowingImages, proxy: proxy)
        } else {
            MailWebView.configuration(rules: rules, allowingImages: allowingImages)
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
        let watcher = PageWatcher()
        view.navigationDelegate = watcher
        view.loadHTMLString(MailHTML.document(html, allowingImages: allowingImages), baseURL: nil)
        await watcher.waitForFinish()
        return (view, watcher)
    }

    private func hostile(_ base: String) -> String {
        """
        <html><head>
        <link rel="stylesheet" href="\(base)/sheet.css">
        <link rel="preconnect" href="\(base)">
        <LINK REL=preconnect HREF="\(base)/shouting">
        <link/rel="preconnect"/href="\(base)/slashes">
        <link rel="dns-prefetch" href="\(base)">
        <link rel="prefetch" href="\(base)/prefetch">
        <link rel="preload" as="image" href="\(base)/preload.png">
        <link rel="icon" href="\(base)/icon.png">
        <meta http-equiv="Link" content="<\(base)/header>; rel=preconnect">
        <style>@import url("\(base)/import.css");
        @font-face{font-family:x;src:url("\(base)/font.woff")}
        body{font-family:x;background:url("\(base)/background.png");cursor:url("\(base)/cursor.png"),auto}
        ul{list-style-image:url("\(base)/list.png")}
        p{background-image:image-set("\(base)/set.png" 1x);mask-image:url("\(base)/mask.png")}</style>
        <base href="\(base)/">
        </head><body background="\(base)/body.png">
        <p id="words">Hello</p><ul><li>Item</li></ul>
        <script>document.getElementById("words").textContent = "script ran"; new Image().src = "\(base)/script.png"</script>
        <img src="\(base)/open.gif"><img src="relative.png"><img srcset="\(base)/srcset.png 2x">
        <picture><source srcset="\(base)/source.png"><img src="\(base)/picture.png"></picture>
        <video src="\(base)/video.mp4" poster="\(base)/poster.png" autoplay></video>
        <audio src="\(base)/audio.mp3" autoplay></audio>
        <iframe src="\(base)/frame.html"></iframe><iframe srcdoc="<img src='\(base)/srcdoc.png'>"></iframe>
        <object data="\(base)/object"></object><embed src="\(base)/embed">
        <svg><image href="\(base)/svg.png"/><use href="\(base)/use.svg#a"/></svg>
        <table background="\(base)/table.png"><tr><td background="\(base)/cell.png">x</td></tr></table>
        <form action="\(base)/form"><input type="image" src="\(base)/input.png"></form>
        </body></html>
        """
    }

    @Test func nothingInAHostileMessageReachesTheNetwork() async throws {
        let tripwire = try Tripwire()
        let port = try await tripwire.start()
        defer { tripwire.stop() }
        // The listener itself works, or a quiet result would mean nothing.
        let probe = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        probe.start(queue: .global())
        defer { probe.cancel() }
        for _ in 0..<200 where tripwire.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tripwire.count == 1)

        let page = try await load(hostile("http://127.0.0.1:\(port)"))
        try await Task.sleep(for: Self.settle)
        #expect(tripwire.count == 1)
        let words = try await page.view.evaluateJavaScript("document.getElementById('words').textContent", in: nil, contentWorld: .defaultClient)
        #expect(words as? String == "Hello")
    }

    @Test func turningImagesOnStillKeepsPlainHTTPAndEverythingElseOut() async throws {
        let tripwire = try Tripwire()
        let port = try await tripwire.start()
        defer { tripwire.stop() }
        let page = try await load(hostile("http://127.0.0.1:\(port)"), allowingImages: true)
        try await Task.sleep(for: Self.settle)
        #expect(tripwire.count == 0)
        withExtendedLifetime(page) {}
    }

    /// Nothing listens on the real proxy, so this swaps in a listener to see what would have reached it.
    /// It proves mail to real addresses goes there, which a local address can't, as those skip proxies.
    @Test(arguments: ["https://example.com", "http://example.com"])
    func whatGetsPastThePageGoesToTheProxyAndNotOut(address: String) async throws {
        let tripwire = try Tripwire()
        let port = try await tripwire.start()
        defer { tripwire.stop() }
        // A web view with the proxy but no link removal, as the page text is written here by hand.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rules = try #require(await MailRules(directory: directory).list(allowingImages: false))
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 600),
            configuration: MailWebView.configuration(rules: rules, allowingImages: false, proxy: .hostPort(host: "127.0.0.1", port: port))
        )
        let watcher = PageWatcher()
        view.navigationDelegate = watcher
        view.loadHTMLString(#"<link rel="preconnect" href="\#(address)"><p>Hello</p>"#, baseURL: nil)
        await watcher.waitForFinish()
        try await Task.sleep(for: Self.settle)
        #expect(tripwire.count > 0)
        withExtendedLifetime(view) {}
    }

    @Test func aRedirectInTheMessageGoesNowhere() async throws {
        let tripwire = try Tripwire()
        let port = try await tripwire.start()
        defer { tripwire.stop() }
        let (view, watcher) = try await load(#"<meta http-equiv="refresh" content="0;url=http://127.0.0.1:\#(port)/moved"><p>Hello</p>"#)
        try await Task.sleep(for: Self.settle)
        #expect(tripwire.count == 0)
        #expect(view.url?.absoluteString == "about:blank")
        #expect(watcher.refused.allSatisfy { $0.host() == "127.0.0.1" })
    }

    @Test func aPageCanBeMeasuredWithItsScriptsOff() async throws {
        let (view, _) = try await load(#"<div style="height:900px">Tall</div>"#)
        let height = try await view.evaluateJavaScript("document.documentElement.scrollHeight", in: nil, contentWorld: .defaultClient)
        #expect((height as? NSNumber)?.intValue ?? 0 >= 900)
    }
}
