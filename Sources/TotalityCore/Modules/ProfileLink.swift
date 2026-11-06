import Foundation

/// The two ways to point at someone's profile: the public web page, which exists only once they've
/// shared it, and the app's own link, which the page's Open in Totality button uses.
public enum ProfileLink {
    public static let appScheme = "totality"

    /// `https://usetotality.com/@username`.
    public static func web(for username: String) -> URL {
        URL(string: "https://\(MailDomain.name)/@\(username.lowercased())")!
    }

    /// The username a link points at, from either kind, or nil for anything else.
    public static func username(in url: URL) -> String? {
        let candidate: String?
        if url.scheme?.lowercased() == appScheme, url.host()?.lowercased() == "profile" {
            candidate = url.pathComponents.count == 2 ? url.pathComponents[1] : nil
        } else if url.scheme?.lowercased() == "https", url.host()?.lowercased() == MailDomain.name,
                  url.pathComponents.count == 2, url.pathComponents[1].hasPrefix("@") {
            candidate = String(url.pathComponents[1].dropFirst())
        } else {
            candidate = nil
        }
        guard let name = candidate?.lowercased(), name.wholeMatch(of: /[a-z0-9_]{3,24}/) != nil else { return nil }
        return name
    }
}
