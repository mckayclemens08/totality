import Foundation
import TotalityCore

/// Where a track originates and how Totality plays it cleanly and honestly.
public enum MusicSourceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case upload
    case openSubsonic
    case appleMusic
    case spotify
    case youTubeMusic

    public var displayName: String {
        switch self {
        case .upload: "My Files"
        case .openSubsonic: "OpenSubsonic"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .youTubeMusic: "YouTube Music"
        }
    }

    public var privacyBadge: String {
        switch self {
        case .upload: AudioSourceBadge.uploaded.rawValue
        case .openSubsonic: AudioSourceBadge.openSubsonic.rawValue
        case .appleMusic: AudioSourceBadge.appleMusic.rawValue
        case .spotify: AudioSourceBadge.spotify.rawValue
        case .youTubeMusic: AudioSourceBadge.youTubeMusic.rawValue
        }
    }

    public var audioBadge: AudioSourceBadge {
        switch self {
        case .upload: .uploaded
        case .openSubsonic: .openSubsonic
        case .appleMusic: .appleMusic
        case .spotify: .spotify
        case .youTubeMusic: .youTubeMusic
        }
    }

    public var systemImage: String {
        switch self {
        case .upload: "lock.doc"
        case .openSubsonic: "server.rack"
        case .appleMusic: "music.note"
        case .spotify: "dot.radiowaves.left.and.right"
        case .youTubeMusic: "play.rectangle"
        }
    }
}

/// One track in Music — uploaded file (sealed with ContentCipher), OpenSubsonic track, or connected stream.
public struct MusicTrack: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var formatLabel: String
    public var source: MusicSourceKind
    /// Opaque identifier within the source: blob UUID for uploads, song ID for Subsonic/Apple Music/Spotify/YouTube.
    public var sourceID: String
    /// Original file extension (e.g. "flac", "mp3", "m4a") kept strictly inside the encrypted catalog.
    public var fileExtension: String
    /// Optional server ID when `source == .openSubsonic`.
    public var serverID: UUID?
    /// Separate sealed artwork blob ID (stripped EXIF JPEG under `KeyPurpose.musicArt`).
    public var artworkID: UUID?
    public var byteCount: Int
    public var isLiked: Bool
    public var isOfflineSaved: Bool
    public var addedAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String = "",
        album: String = "",
        duration: TimeInterval = 0,
        formatLabel: String = "Audio",
        source: MusicSourceKind,
        sourceID: String,
        fileExtension: String = "",
        serverID: UUID? = nil,
        artworkID: UUID? = nil,
        byteCount: Int = 0,
        isLiked: Bool = false,
        isOfflineSaved: Bool = false,
        addedAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.formatLabel = formatLabel
        self.source = source
        self.sourceID = sourceID
        self.fileExtension = fileExtension
        self.serverID = serverID
        self.artworkID = artworkID
        self.byteCount = byteCount
        self.isLiked = isLiked
        self.isOfflineSaved = isOfflineSaved
        self.addedAt = addedAt
        self.updatedAt = updatedAt ?? addedAt
    }

    public var subtitle: String {
        let parts = [artist, album].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? source.displayName : parts.joined(separator: " · ")
    }

    public var formattedDuration: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Unified playlist that can combine tracks from uploads, OpenSubsonic, Apple Music, Spotify, and YouTube Music.
public struct MusicPlaylist: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var trackIDs: [UUID]
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, trackIDs: [UUID] = [], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.updatedAt = updatedAt
    }
}

/// OpenSubsonic / Navidrome / Jellyfin compatible server entry. Passwords live only in device Keychain.
public struct OpenSubsonicServer: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: String
    public var username: String
    public var lastSyncedAt: Date?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        username: String,
        lastSyncedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.lastSyncedAt = lastSyncedAt
        self.updatedAt = updatedAt
    }
}

/// The person's Music library catalog, playlists, and server configurations sealed into one record.
public struct MusicCatalog: Codable, Equatable, Sendable, MergedRecord {
    public var tracks: [MusicTrack]
    public var playlists: [MusicPlaylist]
    public var servers: [OpenSubsonicServer]
    public var removedTrackDates: [UUID: Date]
    public var removedPlaylistDates: [UUID: Date]
    public var removedServerDates: [UUID: Date]

    public init(
        tracks: [MusicTrack] = [],
        playlists: [MusicPlaylist] = [],
        servers: [OpenSubsonicServer] = [],
        removedTrackDates: [UUID: Date] = [:],
        removedPlaylistDates: [UUID: Date] = [:],
        removedServerDates: [UUID: Date] = [:]
    ) {
        self.tracks = tracks
        self.playlists = playlists
        self.servers = servers
        self.removedTrackDates = removedTrackDates
        self.removedPlaylistDates = removedPlaylistDates
        self.removedServerDates = removedServerDates
    }

    public static func merged(_ one: MusicCatalog, _ other: MusicCatalog) -> MusicCatalog {
        let removedTracks = one.removedTrackDates.merging(other.removedTrackDates, uniquingKeysWith: max)
        var trackMap: [UUID: MusicTrack] = [:]
        for item in one.tracks + other.tracks {
            if let removed = removedTracks[item.id], removed >= item.updatedAt { continue }
            if let existing = trackMap[item.id], existing.updatedAt > item.updatedAt { continue }
            trackMap[item.id] = item
        }

        let removedPlaylists = one.removedPlaylistDates.merging(other.removedPlaylistDates, uniquingKeysWith: max)
        var playlistMap: [UUID: MusicPlaylist] = [:]
        for item in one.playlists + other.playlists {
            if let removed = removedPlaylists[item.id], removed >= item.updatedAt { continue }
            if let existing = playlistMap[item.id], existing.updatedAt > item.updatedAt { continue }
            playlistMap[item.id] = item
        }

        let removedServers = one.removedServerDates.merging(other.removedServerDates, uniquingKeysWith: max)
        var serverMap: [UUID: OpenSubsonicServer] = [:]
        for item in one.servers + other.servers {
            if let removed = removedServers[item.id], removed >= item.updatedAt { continue }
            if let existing = serverMap[item.id], existing.updatedAt > item.updatedAt { continue }
            serverMap[item.id] = item
        }

        return MusicCatalog(
            tracks: trackMap.values.sorted { $0.addedAt > $1.addedAt },
            playlists: playlistMap.values.sorted { $0.updatedAt > $1.updatedAt },
            servers: serverMap.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            removedTrackDates: removedTracks,
            removedPlaylistDates: removedPlaylists,
            removedServerDates: removedServers
        )
    }
}

public enum MusicFilterTab: String, CaseIterable, Identifiable, Sendable {
    case library = "Library"
    case playlists = "Playlists"
    case uploads = "Uploads & Servers"
    case connections = "Connections"

    public var id: String { rawValue }
}

public enum MusicRepeatMode: String, Codable, Sendable, CaseIterable {
    case off, one, all
}

/// Connection metadata shown on the Connections screen for external streaming accounts.
public struct StreamingConnectionStatus: Equatable, Sendable {
    public let provider: MusicSourceKind
    public var isConnected: Bool
    public var accountLabel: String
    public var scopesDescription: String
    public var lastSyncedAt: Date?
    public var note: String?

    public init(
        provider: MusicSourceKind,
        isConnected: Bool = false,
        accountLabel: String = "",
        scopesDescription: String,
        lastSyncedAt: Date? = nil,
        note: String? = nil
    ) {
        self.provider = provider
        self.isConnected = isConnected
        self.accountLabel = accountLabel
        self.scopesDescription = scopesDescription
        self.lastSyncedAt = lastSyncedAt
        self.note = note
    }
}
