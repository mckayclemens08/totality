import Foundation

/// Where the backend is. The key is Supabase's publishable key: it identifies the project, and the
/// row-level rules decide what a caller can do. The secret key never ships in the app.
public struct AccountConfig: Sendable, Equatable {
    public let url: URL
    public let publishableKey: String

    public init?(url: String?, publishableKey: String?) {
        guard let url, let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil,
              let publishableKey, !publishableKey.isEmpty
        else { return nil }
        self.url = parsed
        self.publishableKey = publishableKey
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> AccountConfig? {
        AccountConfig(
            url: bundle.object(forInfoDictionaryKey: "TotalityBackendURL") as? String,
            publishableKey: bundle.object(forInfoDictionaryKey: "TotalityBackendKey") as? String
        )
    }
}
