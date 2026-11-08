import Foundation

/// Finding older mail at the provider, past the 90 days each device downloads (issue 43, decision 5).
/// Only from the person's press on the search screen's button, because the words go to the provider,
/// which already keeps that mail. What's found is downloaded and sealed on this device like the rest.
public enum OutsideSearch {
    /// Each account gives this many of its best matches at most.
    public static let most = 50

    /// The words, made safe to send: one line, printable, and not too long. Nil when nothing's left.
    static func words(_ query: String) -> String? {
        // Line breaks and other control characters part words, the way a space does.
        let printable = String(String.UnicodeScalarView(query.unicodeScalars.map { $0.value >= 0x20 && $0.value != 0x7F ? $0 : " " }))
        let joined = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return joined.isEmpty ? nil : String(joined.prefix(200))
    }
}

extension GoogleOAuth {
    /// Gmail's own search, as its search box does it, newest first. Spam and Trash are left out.
    func searchIDs(_ words: String, accessToken: String, limit: Int) async throws -> [String] {
        var components = URLComponents(url: Self.messagesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: words), URLQueryItem(name: "maxResults", value: String(limit))]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        struct Listing: Decodable {
            struct Entry: Decodable { let id: String }
            let messages: [Entry]?
        }
        let listing: Listing = try await gmail(components.url!, accessToken: accessToken)
        return (listing.messages ?? []).map(\.id).filter(Self.isGmailID).prefix(limit).map { $0 }
    }
}

extension IMAPConnection {
    /// The open folder's messages with these words anywhere in them, newest first. Plain ASCII goes as a
    /// quoted string; anything else as a UTF-8 literal, so nothing typed can change the command.
    func search(text words: String) async throws -> [UInt32] {
        let tag = takeTag()
        let isPlain = words.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) }
        if isPlain {
            try await reader.send("\(tag) UID SEARCH TEXT \(Self.quoted(words))")
        } else {
            let bytes = Data(words.utf8)
            try await reader.send("\(tag) UID SEARCH CHARSET UTF-8 TEXT {\(bytes.count)}")
            while true {
                let line = String(decoding: try await reader.line(), as: UTF8.self)
                if line.hasPrefix("+") { break }
                if let answer = Self.answer(line, tag: tag) { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
            }
            try await reader.wire.write(bytes + Data("\r\n".utf8))
        }
        let (untagged, answer) = try await readUntilTagged(tag)
        guard answer.status == .ok else { throw OutsideMailProblem.refused(OutsideMailProblem.providerSaid(answer.text)) }
        var found: [UInt32] = []
        for line in untagged {
            let text = String(decoding: line, as: UTF8.self)
            guard text.uppercased().hasPrefix("* SEARCH") else { continue }
            found += text.dropFirst(8).split(separator: " ").compactMap { UInt32($0) }
        }
        return found.sorted(by: >)
    }
}

extension OutsideReader {
    /// Downloads the provider's matches that aren't here yet. iCloud is searched in its Inbox, where
    /// downloaded mail is followed from; Gmail everywhere but Spam and Trash.
    func search(
        _ words: String, account: OutsideAccount, credential: OutsideCredential,
        have: @Sendable (String) async throws -> Bool, keep: @Sendable (OutsideFetchedMessage) async throws -> Void
    ) async throws {
        switch credential {
        case .google(let grant):
            guard let google else { throw OutsideAccountError.notSetUp }
            let token = try await google.accessToken(for: grant)
            for id in try await google.searchIDs(words, accessToken: token, limit: OutsideSearch.most) {
                try Task.checkCancellation()
                guard try await !have(id) else { continue }
                guard let message = try? await google.message(id, accessToken: token) else { continue }
                try await keep(OutsideFetchedMessage(
                    outside: account.id, providerID: id, received: message.received, raw: message.raw, isUnread: message.isUnread,
                    // Read, archived mail in no tab carries no labels at all. An empty list would read as a copy kept
                    // before labels were, so it says Primary, which is what no tab means at Gmail.
                    isStarred: message.isStarred, labels: message.labels.isEmpty ? ["CATEGORY_PERSONAL"] : message.labels
                ))
            }
        case .appPassword(let password):
            guard let signIn = OutsideSignIn(provider: account.provider, address: account.address, appPassword: password) else {
                throw OutsideAccountError.notFound
            }
            let connection = try await IMAPConnection.signIn(signIn, with: maker)
            do {
                let validity = try await connection.examineInbox()
                var missing: [UInt32] = []
                for uid in try await connection.search(text: words).prefix(OutsideSearch.most) where try await !have("\(validity).\(uid)") {
                    missing.append(uid)
                }
                for start in stride(from: 0, to: missing.count, by: 10) {
                    try Task.checkCancellation()
                    for fetched in try await connection.fetch(Array(missing[start..<min(start + 10, missing.count)])) {
                        try await keep(OutsideFetchedMessage(
                            outside: account.id, providerID: "\(validity).\(fetched.uid)", received: fetched.received ?? Date(),
                            raw: fetched.raw, isUnread: fetched.isUnread, isStarred: fetched.isStarred
                        ))
                    }
                }
                await connection.signOut()
            } catch {
                await connection.signOut()
                throw error
            }
        }
    }
}

/// How the last search of outside accounts went.
public struct OutsideSearchState: Equatable, Sendable {
    public let query: String
    public let isSearching: Bool
    public var found = 0
    public var problems: [String] = []
}
