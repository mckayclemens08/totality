import Foundation

/// Why an outside account couldn't be reached or signed in to. None of these carry the password, and the
/// provider's own words are only kept when they say nothing it wasn't sent.
public enum OutsideMailProblem: Error, Equatable, Sendable {
    case offline
    /// The server didn't answer, or couldn't be found.
    case unreachable
    /// TLS didn't happen, or the certificate didn't check out. Nothing was signed in.
    case insecure
    /// The provider turned the address and app password down.
    case wrongPassword
    /// The provider wants an app password, not the account's own password.
    case needsAppPassword
    /// The provider said no for its own reason, in its own words.
    case refused(String)
    /// The server said something that doesn't fit the protocol.
    case unexpected

    static func from(_ error: any Error) -> OutsideMailProblem {
        if let problem = error as? OutsideMailProblem { return problem }
        guard let url = error as? URLError else { return .unreachable }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .insecure
        default:
            return .unreachable
        }
    }

    /// A provider's words, made safe to show: printable, one line, and short.
    static func providerSaid(_ text: String) -> String {
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        return String(printable.trimmingCharacters(in: .whitespaces).prefix(200))
    }
}
