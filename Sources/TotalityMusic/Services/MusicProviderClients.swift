import CryptoKit
import Foundation
import TotalityCore
#if canImport(MusicKit)
import MusicKit
#endif

public enum MusicProviderError: Error, LocalizedError {
    case missingClientConfiguration(String)
    case notConnected(String)
    case playbackRequiresPhysicalDevice(String)
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientConfiguration(let msg): msg
        case .notConnected(let provider): "\(provider) isn't connected yet."
        case .playbackRequiresPhysicalDevice(let msg): msg
        case .apiError(let msg): msg
        }
    }
}

public struct OAuthTokenBundle: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var accountLabel: String

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date, accountLabel: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountLabel = accountLabel
    }

    public var isExpired: Bool { expiresAt <= Date().addingTimeInterval(60) }
}

/// Manages PKCE OAuth flows, MusicKit library sync, and token storage in the user's Keychain corner
/// for **Apple Music**, **Spotify**, and **YouTube Music**.
public struct MusicProviderManager: Sendable {
    public static let spotifyService = "app.totality.spotify"
    public static let ytMusicService = "app.totality.ytmusic"
    public static let callbackScheme = "totality"
    public static let spotifyRedirectURI = "totality://music-spotify-callback"
    public static let youtubeRedirectURI = "totality://music-youtube-callback"

    public let builtInSpotifyClientID: String?
    public let googleClientID: String?
    private let spotifyStore: (any KeyStore)?
    private let ytMusicStore: (any KeyStore)?

    public var spotifyClientID: String? {
        if let builtInSpotifyClientID { return builtInSpotifyClientID }
        guard let data = try? spotifyStore?.load("spotify.client_id"),
              let saved = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !saved.isEmpty
        else { return nil }
        return saved
    }

    public func saveSpotifyClientID(_ id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try spotifyStore?.delete("spotify.client_id")
            return
        }
        try spotifyStore?.save(Data(trimmed.utf8), as: "spotify.client_id")
    }

    public var youTubeCallbackScheme: String {
        let suffix = ".apps.googleusercontent.com"
        if let googleClientID, googleClientID.hasSuffix(suffix) {
            return "com.googleusercontent.apps." + googleClientID.dropLast(suffix.count)
        }
        return Self.callbackScheme
    }

    public var resolvedYouTubeRedirectURI: String {
        let suffix = ".apps.googleusercontent.com"
        if let googleClientID, googleClientID.hasSuffix(suffix) {
            return youTubeCallbackScheme + ":/oauth2redirect"
        }
        return Self.youtubeRedirectURI
    }

    public init(
        spotifyClientID: String? = nil,
        googleClientID: String? = nil,
        spotifyStore: (any KeyStore)? = nil,
        ytMusicStore: (any KeyStore)? = nil
    ) {
        let trimmedSpotify = spotifyClientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoogle = googleClientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.builtInSpotifyClientID = trimmedSpotify?.isEmpty == true ? nil : trimmedSpotify
        self.googleClientID = trimmedGoogle?.isEmpty == true ? nil : trimmedGoogle
        self.spotifyStore = spotifyStore
        self.ytMusicStore = ytMusicStore
    }

    // MARK: Connection Inspection

    public func connectionStatuses(appleAuthorized: Bool) -> [StreamingConnectionStatus] {
        let spotifyToken = loadToken(from: spotifyStore, name: "spotify.oauth")
        let ytToken = loadToken(from: ytMusicStore, name: "ytmusic.oauth")
        return [
            StreamingConnectionStatus(
                provider: .appleMusic,
                isConnected: appleAuthorized,
                accountLabel: appleAuthorized ? "Apple Music membership" : "",
                scopesDescription: "MusicKit library & playback",
                note: "Requires a physical iPhone with Apple Music permission."
            ),
            StreamingConnectionStatus(
                provider: .spotify,
                isConnected: spotifyToken != nil,
                accountLabel: spotifyToken?.accountLabel ?? "",
                scopesDescription: "user-library-read · playlist-read-private",
                note: spotifyClientID == nil ? "Requires your free Spotify app Client ID (redirect: \(Self.spotifyRedirectURI))." : nil
            ),
            StreamingConnectionStatus(
                provider: .youTubeMusic,
                isConnected: ytToken != nil,
                accountLabel: ytToken?.accountLabel ?? "",
                scopesDescription: "youtube.readonly · embedded player",
                note: googleClientID == nil ? "Set TotalityGoogleClientID in Info.plist to enable Google sign-in." : nil
            ),
        ]
    }

    // MARK: PKCE Helper

    public struct PKCEChallenge: Sendable {
        public let verifier: String
        public let challenge: String

        public init() {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            self.verifier = Self.base64URL(Data(bytes))
            let hash = SHA256.hash(data: Data(verifier.utf8))
            self.challenge = Self.base64URL(Data(hash))
        }

        private static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    // MARK: Spotify

    public func spotifyAuthURL(pkce: PKCEChallenge) throws -> URL {
        guard let spotifyClientID else {
            throw MusicProviderError.missingClientConfiguration("Add TotalitySpotifyClientID to this build's settings to connect Spotify.")
        }
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.spotifyRedirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "scope", value: "user-library-read playlist-read-private user-modify-playback-state"),
        ]
        return comps.url!
    }

    public func exchangeSpotifyCode(_ code: String, verifier: String) async throws -> OAuthTokenBundle {
        guard let spotifyClientID else {
            throw MusicProviderError.missingClientConfiguration("Missing TotalitySpotifyClientID.")
        }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: spotifyClientID),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.spotifyRedirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw MusicProviderError.apiError("Spotify sign-in couldn't be completed.")
        }
        let refresh = json["refresh_token"] as? String
        let expires = (json["expires_in"] as? Double) ?? 3600
        let bundle = OAuthTokenBundle(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expires),
            accountLabel: "Connected Spotify"
        )
        try saveToken(bundle, to: spotifyStore, name: "spotify.oauth")
        return bundle
    }

    public func fetchSpotifySavedTracks(limit: Int = 40) async throws -> [MusicTrack] {
        guard let token = loadToken(from: spotifyStore, name: "spotify.oauth") else {
            throw MusicProviderError.notConnected("Spotify")
        }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks?limit=\(limit)")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw MusicProviderError.apiError("Couldn't read Spotify saved tracks.")
        }
        return items.compactMap { entry in
            guard let track = entry["track"] as? [String: Any],
                  let uri = track["uri"] as? String,
                  let name = track["name"] as? String else { return nil }
            let artists = (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
            let album = (track["album"] as? [String: Any])?["name"] as? String ?? ""
            let ms = (track["duration_ms"] as? Double) ?? 0
            return MusicTrack(
                title: name,
                artist: artists,
                album: album,
                duration: ms / 1000.0,
                formatLabel: "Spotify",
                source: .spotify,
                sourceID: uri
            )
        }
    }

    public func disconnectSpotify() {
        try? spotifyStore?.delete("spotify.oauth")
    }

    // MARK: YouTube Music (Google OAuth + YouTube Data API v3)

    public func youTubeAuthURL(pkce: PKCEChallenge) throws -> URL {
        guard let googleClientID else {
            throw MusicProviderError.missingClientConfiguration("Add TotalityGoogleClientID to this build's settings to connect YouTube Music.")
        }
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: googleClientID),
            URLQueryItem(name: "redirect_uri", value: resolvedYouTubeRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid https://www.googleapis.com/auth/youtube.readonly"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        return comps.url!
    }

    public func exchangeYouTubeCode(_ code: String, verifier: String) async throws -> OAuthTokenBundle {
        guard let googleClientID else {
            throw MusicProviderError.missingClientConfiguration("Missing TotalityGoogleClientID.")
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: googleClientID),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: resolvedYouTubeRedirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw MusicProviderError.apiError("Google sign-in for YouTube Music couldn't be completed.")
        }
        let refresh = json["refresh_token"] as? String
        let expires = (json["expires_in"] as? Double) ?? 3600
        let bundle = OAuthTokenBundle(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expires),
            accountLabel: "Connected YouTube Music"
        )
        try saveToken(bundle, to: ytMusicStore, name: "ytmusic.oauth")
        return bundle
    }

    public func fetchYouTubeLikedTracks(limit: Int = 30) async throws -> [MusicTrack] {
        guard let token = loadToken(from: ytMusicStore, name: "ytmusic.oauth") else {
            throw MusicProviderError.notConnected("YouTube Music")
        }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/videos?part=snippet&myRating=like&maxResults=\(limit)")!)
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw MusicProviderError.apiError("Couldn't read YouTube liked tracks.")
        }
        return items.compactMap { item in
            guard let videoID = item["id"] as? String,
                  let snippet = item["snippet"] as? [String: Any],
                  let title = snippet["title"] as? String else { return nil }
            let channel = snippet["channelTitle"] as? String ?? "YouTube"
            return MusicTrack(
                title: title,
                artist: channel,
                album: "YouTube Music",
                duration: 0,
                formatLabel: "YouTube",
                source: .youTubeMusic,
                sourceID: videoID
            )
        }
    }

    public func disconnectYouTubeMusic() {
        try? ytMusicStore?.delete("ytmusic.oauth")
    }

    // MARK: Apple Music (MusicKit)

    public func isAppleMusicAuthorized() -> Bool {
        #if canImport(MusicKit)
        return MusicAuthorization.currentStatus == .authorized
        #else
        return false
        #endif
    }

    public func requestAppleMusicAccessAndFetch() async throws -> [MusicTrack] {
        #if canImport(MusicKit)
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            throw MusicProviderError.notConnected("Apple Music permission wasn't granted")
        }
        var request = MusicLibraryRequest<Song>()
        request.limit = 40
        let response = try await request.response()
        return response.items.map { song in
            MusicTrack(
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle ?? "",
                duration: song.duration ?? 0,
                formatLabel: "Apple Music",
                source: .appleMusic,
                sourceID: song.id.rawValue
            )
        }
        #else
        throw MusicProviderError.playbackRequiresPhysicalDevice("MusicKit isn't supported on this platform build.")
        #endif
    }

    public func playAppleMusicTrack(id rawID: String) async throws {
        #if canImport(MusicKit)
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(rawID))
        let response = try await request.response()
        guard let song = response.items.first else {
            throw MusicProviderError.apiError("That Apple Music track wasn't found.")
        }
        ApplicationMusicPlayer.shared.queue = [song]
        try await ApplicationMusicPlayer.shared.play()
        #else
        throw MusicProviderError.playbackRequiresPhysicalDevice("Apple Music playback requires MusicKit on an iPhone.")
        #endif
    }

    // MARK: Token Storage

    public func saveToken(_ bundle: OAuthTokenBundle, to store: (any KeyStore)?, name: String) throws {
        guard let store else { return }
        let data = try JSONEncoder().encode(bundle)
        try store.save(data, as: name)
    }

    public func loadToken(from store: (any KeyStore)?, name: String) -> OAuthTokenBundle? {
        guard let data = try? store?.load(name) else { return nil }
        return try? JSONDecoder().decode(OAuthTokenBundle.self, from: data)
    }
}
