import Foundation

/// What went wrong talking to the Matrix server, sorted so the person is told the truth. Only a real
/// network failure is called a connection problem. Anything else says it didn't go through, with a short
/// code the owner can quote back to us. The app turns the SDK's errors into one of these.
public enum MatrixFailure: Equatable, Sendable {
    /// The request never reached the server, or its answer never came back.
    case offline
    /// The server answered with a Matrix error code, such as M_FORBIDDEN or M_LIMIT_EXCEEDED.
    case server(code: String)
    /// The SDK failed on the device without a Matrix error code. Its own words, which may name people or
    /// rooms, are never shown as they are: see `MatrixFailure.code(_:)`.
    case sdk(String)

    /// The SDK's words for a failure that is really the network, so it still says offline.
    public static func fromSDK(_ message: String) -> MatrixFailure {
        isNetwork(message) ? .offline : .sdk(message)
    }

    public var error: MessagesError {
        switch self {
        case .offline:
            return .offline
        case .server(let code):
            let code = code.range(of: #"^[A-Za-z0-9_.]{1,64}$"#, options: .regularExpression) != nil ? code : "unknown code"
            switch code {
            case "M_FORBIDDEN": return .failed("The Matrix server refused that.")
            case "M_LIMIT_EXCEEDED": return .failed("The server asked us to slow down. Wait a moment and try again.")
            default: return .failed("That didn't go through (\(code)).")
            }
        case .sdk(let message):
            return .failed("That didn't go through (\(Self.code(message))).")
        }
    }

    // MARK: Telling the network apart

    private static let networkWords = [
        "error sending request", "connection refused", "connection reset", "connection closed",
        "connection aborted", "connect error", "tcp connect", "timed out", "timeout", "dns error",
        "failed to lookup address", "network is unreachable", "network is down", "host is unreachable",
        "not connected to the internet", "broken pipe", "offline",
    ]

    static func isNetwork(_ message: String) -> Bool {
        let lower = message.lowercased()
        return networkWords.contains { lower.contains($0) }
    }

    // MARK: A code safe to show

    /// The longest code shown, in characters.
    static let codeLength = 80

    /// A short, quotable form of an error's words with anything personal taken out: Matrix IDs of people,
    /// rooms and events, links, email addresses, quoted text and long tokens all become "…". It is cut to
    /// `codeLength` characters, so a long message never fills the screen.
    public static func code(_ message: String) -> String {
        var text = message
        let patterns = [
            #"https?://\S+"#,                                   // links
            #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, // email addresses
            #"[@!#$+][^\s:'"`,;()\[\]{}]+(:[A-Za-z0-9.\-]+(:\d+)?)?"#, // user, room, alias and event IDs
            // Anything quoted, which may be content. An apostrophe inside a word, as in "doesn't", isn't a quote.
            #""[^"]*"|`[^`]*`|(?<![A-Za-z])'[^']*'(?![A-Za-z])"#,
            #"(?=[A-Za-z+/=_\-]*[0-9])[A-Za-z0-9+/=_\-]{16,}"#,      // keys, tokens, long hashes
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "…", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"…( ?…)+"#, with: "…", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:")))
        if text.isEmpty || text == "…" { return "unknown error" }
        if text.count > codeLength { text = String(text.prefix(codeLength - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        return text
    }
}

/// Waits for something the server sends a moment later, such as a new room's settings arriving with the
/// next sync. True once `isReady` says so, false if it never did in time.
public enum MatrixWait {
    public static func until(
        attempts: Int = 75, every interval: Duration = .milliseconds(200),
        isolation: isolated (any Actor)? = #isolation,
        _ isReady: () async -> Bool
    ) async throws -> Bool {
        for attempt in 0..<max(attempts, 1) {
            if await isReady() { return true }
            if attempt < attempts - 1 { try await Task.sleep(for: interval) }
        }
        return false
    }
}
