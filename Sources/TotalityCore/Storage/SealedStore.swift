import CryptoKit
import Foundation

/// Where sealed blobs are kept. It's configuration, not code (proposal §11-H): the app reads it from
/// `TotalitySealedStoreURL` in its Info.plist, so the store can move from the Oracle server to the home
/// server by copying the files and changing this one setting. Blob IDs stay the same wherever they live.
public struct SealedStoreTarget: Sendable, Equatable {
    /// The Oracle server, until the home server exists (issue 54).
    public static let standard = SealedStoreTarget(url: "https://usetotality.com/blobs/")!

    public let url: URL

    /// Only HTTPS, with a host and nothing after the path.
    public init?(url text: String?) {
        guard let text, var components = URLComponents(string: text), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil
        else { return nil }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let url = components.url else { return nil }
        self.url = url
    }

    /// The bundle's setting, or the standard target when it's missing or isn't a usable address.
    public static func fromBundle(_ bundle: Bundle = .main) -> SealedStoreTarget {
        SealedStoreTarget(url: bundle.object(forInfoDictionaryKey: "TotalitySealedStoreURL") as? String) ?? .standard
    }
}

/// How a row names a blob in the sealed store, as against a Supabase Storage path:
/// `<owner>/sealed/<blob>`. It starts with the owner, as the database requires of every key, and never
/// says which server, so moving the store changes no rows.
public enum SealedBlobKey {
    public static func key(owner: String, blob: UUID) -> String {
        "\(owner.lowercased())/sealed/\(blob.uuidString.lowercased())"
    }

    /// The blob's ID, or nil when the key is anything else, like a Supabase path or another owner's key.
    public static func blob(in key: String, owner: String) -> UUID? {
        let prefix = "\(owner.lowercased())/sealed/"
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard rest.count == 36, rest == rest.lowercased() else { return nil }
        return UUID(uuidString: String(rest))
    }

    /// Whether a key names the sealed store at all, whoever it belongs to.
    public static func isSealed(_ key: String) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[1] == "sealed"
    }

    /// The blob for one version of an item's body. The same body always gets the same blob, so a retry
    /// or another device landing the same bytes never stores them twice. It's made from hashes of
    /// ciphertext, so it says nothing.
    public static func blob(owner: String, item: UUID, bodyHash: String) -> UUID {
        UUID(derivedFrom: "totality/sealed-body/v1/\(owner.lowercased())/\(item.uuidString.lowercased())/\(bodyHash)")
    }
}

public enum SealedStoreError: Error, Equatable, Sendable {
    case signedOut, offline, unavailable
    /// The account's limit is reached, or the server is short of disk.
    case full
    /// Bigger than one blob can be.
    case tooBig
    /// What arrived isn't what was sent, so the blob was never finished.
    case mismatch
}

public struct SealedStoreUsage: Codable, Equatable, Sendable {
    public let used: Int
    public let limit: Int

    public init(used: Int, limit: Int) {
        self.used = used
        self.limit = limit
    }

    public var left: Int { max(0, limit - used) }
}

public struct SealedStoreEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let size: Int

    public init(id: UUID, size: Int) {
        self.id = id
        self.size = size
    }
}

/// The sealed blob store, as any module sees it. Everything handed to it must already be sealed: the
/// store keeps bytes, and anyone who runs it can read the bytes. The account is always the signed-in one.
public protocol SealedStore: Sendable {
    /// Stores a blob under a fresh random ID, picking up where an earlier try stopped. Storing the same
    /// ID again once it's finished is harmless and changes nothing.
    func put(_ sealed: Data, as id: UUID) async throws
    /// The whole blob, or nil when this account has nothing under that ID.
    func get(_ id: UUID) async throws -> Data?
    /// The blob's size when it's finished, or nil.
    func size(of id: UUID) async throws -> Int?
    func delete(_ id: UUID) async throws
    func usage() async throws -> SealedStoreUsage
    func list() async throws -> [SealedStoreEntry]
}

/// Talks to the sealed store over HTTPS. A blob goes up in pieces small enough for Cloudflare, each at
/// the offset the server says it has, and is finished with its size and SHA-256 so nothing damaged on
/// the way is ever kept. IDs go in the path only because they're random and say nothing. Nothing is
/// cached, and nothing is logged.
public struct SealedStoreClient: SealedStore {
    /// Pieces of this size, under the server's 32 MiB and Cloudflare's 100 MB.
    public static let pieceSize = 8 * 1024 * 1024
    /// The server's own limit for one blob.
    public static let maxBlob = 5 * 1024 * 1024 * 1024

    private let target: SealedStoreTarget
    private let session: URLSession
    private let pieceSize: Int
    private let token: @Sendable () async throws -> String

    public init(
        target: SealedStoreTarget = .fromBundle(), session: URLSession? = nil, pieceSize: Int = SealedStoreClient.pieceSize,
        token: @escaping @Sendable () async throws -> String
    ) {
        self.target = target
        self.token = token
        self.pieceSize = max(1, min(pieceSize, Self.pieceSize))
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    public func put(_ sealed: Data, as id: UUID) async throws {
        guard !sealed.isEmpty else { throw SealedStoreError.mismatch }
        guard sealed.count <= Self.maxBlob else { throw SealedStoreError.tooBig }
        var offset: Int
        switch try await state(of: id) {
        case .done(let size):
            // IDs are random and made for one blob, so a finished one is an earlier try that landed.
            guard size == sealed.count else { throw SealedStoreError.mismatch }
            return
        case .uploading(let at):
            offset = at <= sealed.count ? at : 0
            if at > sealed.count {
                try await delete(id)
            }
        case .missing:
            offset = 0
        }
        // A wrong offset is answered with the right one, so a few tries always settle it.
        var corrections = 0
        while offset < sealed.count {
            let end = min(offset + pieceSize, sealed.count)
            let (status, headers, _) = try await send(
                id.uuidString.lowercased(), method: "PATCH", body: sealed.subdata(in: offset..<end),
                headers: ["Upload-Offset": String(offset), "Content-Type": "application/octet-stream"]
            )
            switch status {
            case 204:
                guard let next = headers["upload-offset"].flatMap(Int.init), next == end else { throw SealedStoreError.unavailable }
                offset = next
            case 409:
                corrections += 1
                guard corrections <= 3 else { throw SealedStoreError.unavailable }
                if headers["blob-state"] == "done" { return try await put(sealed, as: id) }
                guard let actual = headers["upload-offset"].flatMap(Int.init), actual >= 0, actual <= sealed.count else {
                    throw SealedStoreError.unavailable
                }
                offset = actual
            case 413: throw SealedStoreError.tooBig
            case 507: throw SealedStoreError.full
            default: throw Self.error(for: status)
            }
        }
        let hash = SHA256.hash(data: sealed).map { String(format: "%02x", $0) }.joined()
        let finish = try JSONSerialization.data(withJSONObject: ["size": sealed.count, "sha256": hash])
        let (status, _, _) = try await send(id.uuidString.lowercased(), method: "POST", body: finish, headers: ["Content-Type": "application/json"])
        switch status {
        case 201: return
        case 409:
            guard case .done(let size) = try await state(of: id), size == sealed.count else { throw SealedStoreError.mismatch }
        case 400:
            // The bytes that arrived aren't these, so they're thrown away and the next try starts clean.
            try? await delete(id)
            throw SealedStoreError.mismatch
        default: throw Self.error(for: status)
        }
    }

    public func get(_ id: UUID) async throws -> Data? {
        let (status, _, data) = try await send(id.uuidString.lowercased(), method: "GET")
        switch status {
        case 200: return data
        case 404: return nil
        default: throw Self.error(for: status)
        }
    }

    public func size(of id: UUID) async throws -> Int? {
        if case .done(let size) = try await state(of: id) { return size }
        return nil
    }

    public func delete(_ id: UUID) async throws {
        let (status, _, _) = try await send(id.uuidString.lowercased(), method: "DELETE")
        guard status == 204 else { throw Self.error(for: status) }
    }

    public func usage() async throws -> SealedStoreUsage {
        let (status, _, data) = try await send("usage", method: "GET")
        guard status == 200 else { throw Self.error(for: status) }
        guard let usage = try? JSONDecoder().decode(SealedStoreUsage.self, from: data), usage.used >= 0, usage.limit >= 0 else {
            throw SealedStoreError.unavailable
        }
        return usage
    }

    public func list() async throws -> [SealedStoreEntry] {
        let (status, _, data) = try await send("list", method: "GET")
        guard status == 200 else { throw Self.error(for: status) }
        struct Answer: Decodable { let blobs: [SealedStoreEntry] }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw SealedStoreError.unavailable }
        return answer.blobs
    }

    private enum State {
        case missing, uploading(Int), done(Int)
    }

    private func state(of id: UUID) async throws -> State {
        let (status, headers, _) = try await send(id.uuidString.lowercased(), method: "HEAD")
        switch status {
        case 404: return .missing
        case 200:
            if headers["blob-state"] == "done", let size = headers["blob-size"].flatMap(Int.init), size >= 0 { return .done(size) }
            if headers["blob-state"] == "uploading", let offset = headers["upload-offset"].flatMap(Int.init), offset >= 0 {
                return .uploading(offset)
            }
            throw SealedStoreError.unavailable
        default: throw Self.error(for: status)
        }
    }

    private static func error(for status: Int) -> SealedStoreError {
        switch status {
        case 401: .signedOut
        case 507: .full
        case 413: .tooBig
        default: .unavailable
        }
    }

    /// Header names come back lowercased.
    private func send(
        _ path: String, method: String, body: Data? = nil, headers: [String: String] = [:]
    ) async throws -> (Int, [String: String], Data) {
        let bearer: String
        do {
            bearer = try await token()
        } catch {
            throw SealedStoreError.signedOut
        }
        var request = URLRequest(url: target.url.appending(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.offline.contains(error.code) {
            throw SealedStoreError.offline
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SealedStoreError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw SealedStoreError.unavailable }
        var fields: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { fields[name.lowercased()] = value }
        }
        return (http.statusCode, fields, data)
    }

    private static let offline: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotConnectToHost, .cannotFindHost, .timedOut,
    ]
}
