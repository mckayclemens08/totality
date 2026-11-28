import CryptoKit
import Foundation
import TotalityCore

public enum OpenSubsonicError: Error, LocalizedError {
    case invalidURL
    case missingCredentials
    case serverError(String)
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid OpenSubsonic server URL (HTTPS recommended)."
        case .missingCredentials: "Password for this OpenSubsonic server isn't saved on this device."
        case .serverError(let message): "Server returned an error: \(message)"
        case .httpError(let code): "Server returned HTTP \(code)."
        }
    }
}

/// Client for OpenSubsonic / Navidrome / Gonic / Jellyfin Subsonic REST servers (protocol 1.16+).
/// Credentials stay inside the account's Keychain corner and streams connect directly from device to server.
public struct OpenSubsonicClient: Sendable {
    public static let service = "app.totality.opensubsonic"

    public typealias DataFetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    private let keyStore: (any KeyStore)?
    private let fetcher: DataFetcher

    public init(
        keyStore: (any KeyStore)? = nil,
        fetcher: @escaping DataFetcher = { url in try await URLSession.shared.data(from: url) }
    ) {
        self.keyStore = keyStore
        self.fetcher = fetcher
    }

    public func savePassword(_ password: String, for serverID: UUID) throws {
        try keyStore?.save(Data(password.utf8), as: Self.secretName(for: serverID))
    }

    public func loadPassword(for serverID: UUID) throws -> String? {
        guard let data = try keyStore?.load(Self.secretName(for: serverID)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deletePassword(for serverID: UUID) {
        try? keyStore?.delete(Self.secretName(for: serverID))
    }

    public static func secretName(for serverID: UUID) -> String {
        "opensubsonic.\(serverID.uuidString.lowercased()).password"
    }

    public func ping(server: OpenSubsonicServer, password: String? = nil) async throws {
        let pass = try resolvePassword(serverID: server.id, override: password)
        let url = try buildURL(server: server, endpoint: "ping.view", password: pass)
        _ = try await performEnvelope(url: url)
    }

    public func fetchTracks(server: OpenSubsonicServer, limit: Int = 50, password: String? = nil) async throws -> [MusicTrack] {
        let pass = try resolvePassword(serverID: server.id, override: password)
        let url = try buildURL(
            server: server,
            endpoint: "getRandomSongs.view",
            extra: [URLQueryItem(name: "size", value: String(limit))],
            password: pass
        )
        let json = try await performEnvelope(url: url)
        let container = (json["randomSongs"] as? [String: Any])?["song"] as? [[String: Any]] ?? []
        return container.compactMap { parseSong($0, server: server) }
    }

    public func searchTracks(server: OpenSubsonicServer, query: String, limit: Int = 30, password: String? = nil) async throws -> [MusicTrack] {
        let pass = try resolvePassword(serverID: server.id, override: password)
        let url = try buildURL(
            server: server,
            endpoint: "search3.view",
            extra: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "songCount", value: String(limit)),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
            ],
            password: pass
        )
        let json = try await performEnvelope(url: url)
        let songs = ((json["searchResult3"] as? [String: Any])?["song"] as? [[String: Any]]) ?? []
        return songs.compactMap { parseSong($0, server: server) }
    }

    public func streamURL(for track: MusicTrack, server: OpenSubsonicServer) throws -> URL {
        let pass = try resolvePassword(serverID: server.id, override: nil)
        return try buildURL(
            server: server,
            endpoint: "stream.view",
            extra: [URLQueryItem(name: "id", value: track.sourceID)],
            password: pass
        )
    }

    private func resolvePassword(serverID: UUID, override: String?) throws -> String {
        if let override, !override.isEmpty { return override }
        if let loaded = try loadPassword(for: serverID), !loaded.isEmpty { return loaded }
        throw OpenSubsonicError.missingCredentials
    }

    private func parseSong(_ dict: [String: Any], server: OpenSubsonicServer) -> MusicTrack? {
        guard let songID = dict["id"] as? String ?? (dict["id"] as? Int).map(String.init),
              let title = dict["title"] as? String else { return nil }
        let artist = dict["artist"] as? String ?? ""
        let album = dict["album"] as? String ?? ""
        let duration = TimeInterval((dict["duration"] as? Int) ?? Int(dict["duration"] as? Double ?? 0))
        let suffix = (dict["suffix"] as? String ?? "STREAM").uppercased()
        let size = dict["size"] as? Int ?? 0
        return MusicTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            formatLabel: suffix,
            source: .openSubsonic,
            sourceID: songID,
            fileExtension: suffix.lowercased(),
            serverID: server.id,
            byteCount: size
        )
    }

    func buildURL(
        server: OpenSubsonicServer,
        endpoint: String,
        extra: [URLQueryItem] = [],
        password: String
    ) throws -> URL {
        guard var base = URL(string: server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw OpenSubsonicError.invalidURL
        }
        if base.path.hasSuffix("/") {
            base.appendPathComponent("rest")
        } else {
            base.appendPathComponent("rest")
        }
        base.appendPathComponent(endpoint)

        let salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        let token = Self.md5Hex(password + salt)

        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw OpenSubsonicError.invalidURL
        }
        var items = [
            URLQueryItem(name: "u", value: server.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Totality"),
            URLQueryItem(name: "f", value: "json"),
        ]
        items.append(contentsOf: extra)
        comps.queryItems = items
        guard let final = comps.url else { throw OpenSubsonicError.invalidURL }
        return final
    }

    private func performEnvelope(url: URL) async throws -> [String: Any] {
        let (data, response) = try await fetcher(url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenSubsonicError.httpError(http.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = root["subsonic-response"] as? [String: Any] else {
            throw OpenSubsonicError.serverError("Unexpected server response.")
        }
        if let status = envelope["status"] as? String, status != "ok" {
            let msg = (envelope["error"] as? [String: Any])?["message"] as? String ?? "Authentication failed"
            throw OpenSubsonicError.serverError(msg)
        }
        return envelope
    }

    static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
