import CryptoKit
import Foundation
import WebKit

/// Ads and trackers, stopped by WebKit's own rule lists. The list ships with the app, and WebKit compiles
/// it once, so the first launch takes a few seconds in the background and later ones take none.
@MainActor
public final class WebBlocker {
    public private(set) var rules: WKContentRuleList?

    private let store: WKContentRuleListStore

    public init(store: WKContentRuleListStore = .default()) {
        self.store = store
    }

    public func prepare() async {
        guard rules == nil, let file = Bundle.module.url(forResource: "blocklist", withExtension: "json"),
              let list = await Task.detached(operation: { Self.read(file) }).value
        else { return }
        await prepare(encoded: list.encoded, identifier: list.identifier)
    }

    /// The identifier carries the list's hash, so an app update with a new list compiles it once.
    func prepare(encoded: String, identifier: String) async {
        let found = await withCheckedContinuation { (done: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in done.resume(returning: list) }
        }
        if let found {
            rules = found
            return
        }
        rules = await withCheckedContinuation { (done: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) { list, _ in
                done.resume(returning: list)
            }
        }
        store.getAvailableContentRuleListIdentifiers { [store] identifiers in
            for old in identifiers ?? [] where old != identifier {
                store.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
    }

    private nonisolated static func read(_ file: URL) -> (encoded: String, identifier: String)? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return (String(decoding: data, as: UTF8.self), "blocklist-\(hash)")
    }
}

/// How blocking names a site: the host, without the `www.` most sites answer on too.
enum WebSite {
    static func key(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
