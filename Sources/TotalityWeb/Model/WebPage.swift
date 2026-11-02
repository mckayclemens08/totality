import WebKit
#if os(iOS)
import UIKit
#endif

/// Why a page didn't load.
public enum WebPageFailure: Equatable, Sendable {
    case offline, insecure, other

    public var title: String {
        switch self {
        case .offline: "You're offline"
        case .insecure: "This site's security certificate isn't valid"
        case .other: "This page didn't load"
        }
    }

    public var detail: String {
        switch self {
        case .offline: "Check your connection and try again."
        case .insecure: "Someone could be reading what you send it, so Totality won't open it."
        case .other: "The site didn't answer. It may be down."
        }
    }

    public var canRetry: Bool { self != .insecure }

    static func of(_ error: any Error) -> WebPageFailure? {
        let error = error as NSError
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return nil }
        // A link handed off to a download or another app stops the page. That isn't a failure.
        guard error.domain != "WebKitErrorDomain" || error.code != 102 else { return nil }
        guard error.domain == NSURLErrorDomain else { return .other }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return .offline
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return .insecure
        default:
            return .other
        }
    }
}

/// An alert a page raised. Pages wait on these, so one left unanswered would hang the site.
@MainActor
public struct WebDialog: Identifiable {
    public enum Kind {
        case alert
        case confirm
        case prompt(placeholder: String)
    }

    public let id = UUID()
    public let site: String
    public let message: String
    public let kind: Kind
    /// True or false for the buttons, with the text typed when there's a prompt.
    let answer: @MainActor (Bool, String?) -> Void
}

/// One web page, with its own engine state. Pages get no route into Totality: there's no message
/// handler, no injected script, and no shared storage with the app, so nothing on a page can reach the
/// person's sign-in, keys, or content.
@MainActor
@Observable
public final class WebPage: NSObject {
    public let webView: WKWebView
    public let isPrivate: Bool

    public private(set) var title = ""
    public private(set) var url: URL?
    public private(set) var progress = 0.0
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    /// False when any part of the page came over plain HTTP.
    public private(set) var isSecure = true
    public private(set) var failure: WebPageFailure?
    public var dialog: WebDialog?
    /// A link that belongs to another app, waiting for the person to agree.
    public var leaving: URL?

    /// A page finished loading.
    @ObservationIgnored var onVisit: ((URL, String) -> Void)?
    /// A tap on a page asked for a new tab. Returns its web view, which has to use this configuration.
    @ObservationIgnored var onNewTab: ((WKWebViewConfiguration, URLRequest) -> WKWebView?)?

    @ObservationIgnored private var watches: [NSKeyValueObservation] = []

    public static func configuration(isPrivate: Bool, store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : store
        // A page can open a tab only from a tap. WebKit enforces that when this is off.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.upgradeKnownHostsToHTTPS = true
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        #endif
        return configuration
    }

    public init(configuration: WKWebViewConfiguration, isPrivate: Bool) {
        self.isPrivate = isPrivate
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            self?.reload()
            refresh?.endRefreshing()
        }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        #endif
        watch()
    }

    private func watch() {
        let refresh: @Sendable (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        watches = [
            webView.observe(\.title) { view, _ in refresh(view) },
            webView.observe(\.url) { view, _ in refresh(view) },
            webView.observe(\.estimatedProgress) { view, _ in refresh(view) },
            webView.observe(\.isLoading) { view, _ in refresh(view) },
            webView.observe(\.canGoBack) { view, _ in refresh(view) },
            webView.observe(\.canGoForward) { view, _ in refresh(view) },
            webView.observe(\.hasOnlySecureContent) { view, _ in refresh(view) },
        ]
    }

    private func refresh() {
        title = webView.title ?? ""
        url = webView.url ?? url
        progress = webView.estimatedProgress
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isSecure = webView.url == nil || webView.hasOnlySecureContent
    }

    public func load(_ url: URL) {
        failure = nil
        self.url = url
        webView.load(URLRequest(url: url))
    }

    public func reload() {
        failure = nil
        if webView.url == nil, let url { load(url) } else { webView.reload() }
    }

    public func stop() { webView.stopLoading() }
    public func goBack() { failure = nil; webView.goBack() }
    public func goForward() { failure = nil; webView.goForward() }

    public func answer(_ dialog: WebDialog, _ agreed: Bool, text: String? = nil) {
        self.dialog = nil
        dialog.answer(agreed, text)
    }

    /// Only ordinary web addresses stay in the page. These stay too, because pages use them for their own parts.
    private static let pageSchemes: Set<String> = ["http", "https", "about", "blob", "data"]

    private var site: String {
        webView.url?.host()?.replacing(/^www\./, with: "") ?? "This page"
    }

    private func shown(_ error: any Error) {
        failure = WebPageFailure.of(error)
    }
}

extension WebPage: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url, let scheme = target.scheme?.lowercased() else { return .cancel }
        guard Self.pageSchemes.contains(scheme) else {
            // A site can't hand off to another app by itself. `file:` and the like are simply refused.
            if action.navigationType == .linkActivated, !["file", "ftp"].contains(scheme) { leaving = target }
            return .cancel
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh()
        if let url = webView.url { onVisit?(url, webView.title ?? "") }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        shown(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        shown(error)
    }

    /// A crashed page would otherwise stay blank.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }
}

extension WebPage: WKUIDelegate {
    /// WebKit only asks after a tap, because `javaScriptCanOpenWindowsAutomatically` is off.
    public func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        onNewTab?(configuration, action.request)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            dialog = WebDialog(site: site, message: message, kind: .alert) { _, _ in done.resume() }
        }
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { done in
            dialog = WebDialog(site: site, message: message, kind: .confirm) { agreed, _ in done.resume(returning: agreed) }
        }
    }

    public func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        await withCheckedContinuation { done in
            dialog = WebDialog(site: site, message: prompt, kind: .prompt(placeholder: defaultText ?? "")) { agreed, text in
                done.resume(returning: agreed ? text ?? "" : nil)
            }
        }
    }

    #if os(macOS)
    public func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return await panel.begin() == .OK ? panel.urls : nil
    }
    #endif
}
