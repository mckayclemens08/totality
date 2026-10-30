import Foundation

/// A username, which is also the handle people know you by. Supabase Auth needs an address, so each
/// username maps to one under a reserved domain that can't receive mail. Nothing is ever sent there.
public struct Username: Equatable, Sendable {
    public let value: String

    private static let domain = "@totality.invalid"

    /// Same rule as `profiles.handle` and the auth trigger. Input is lowercased, not refused.
    public init?(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...24).contains(cleaned.count),
              cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { return nil }
        value = cleaned
    }

    init?(address: String) {
        guard address.hasSuffix(Self.domain) else { return nil }
        self.init(String(address.dropLast(Self.domain.count)))
    }

    var address: String { value + Self.domain }
}
