import Foundation
import Observation
import TotalityCore
#if canImport(UIKit)
import UIKit
#endif

/// Main observable state and queue engine for Totality Music (`.player`).
@MainActor
@Observable
public final class MusicModel {
    public enum Phase: Equatable {
        case idle, loading, ready
    }

    public private(set) var phase = Phase.idle
    public private(set) var catalog = MusicCatalog()
    public private(set) var activeTab = MusicFilterTab.library
    public var selectedSourceFilter: MusicSourceKind? = nil
    public var searchQuery = ""

    public private(set) var queue: [MusicTrack] = []
    public private(set) var queueIndex = 0
    public var isShuffled = false
    public var repeatMode: MusicRepeatMode = .off

    public private(set) var isImporting = false
    public private(set) var isSyncing = false
    public var notice: String?
    public var requestedItemID: String?
    /// Active YouTube video ID when playing a track through the TOS-compliant embedded WebKit player.
    public var activeYouTubeTrack: MusicTrack?

    public let player: MusicAudioPlayer
    @ObservationIgnored public let vault: MusicVault
    @ObservationIgnored public let subsonic: OpenSubsonicClient
    @ObservationIgnored public let providers: MusicProviderManager
    @ObservationIgnored private var artworkCache: [UUID: Data] = [:]

    public init(
        vault: MusicVault,
        subsonic: OpenSubsonicClient = OpenSubsonicClient(),
        providers: MusicProviderManager = MusicProviderManager(),
        audioFocus: AudioTransportCoordinator? = nil
    ) {
        self.vault = vault
        self.subsonic = subsonic
        self.providers = providers
        self.player = MusicAudioPlayer()
        self.player.audioFocus = audioFocus
        self.player.onTrackFinished = { [weak self] in
            Task { @MainActor in
                await self?.advanceAfterFinish()
            }
        }
    }

    // MARK: Derived Library & Glance

    public var filteredTracks: [MusicTrack] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.tracks.filter { track in
            if let filter = selectedSourceFilter, track.source != filter { return false }
            guard !q.isEmpty else { return true }
            return track.title.lowercased().contains(q)
                || track.artist.lowercased().contains(q)
                || track.album.lowercased().contains(q)
        }
    }

    public var connections: [StreamingConnectionStatus] {
        providers.connectionStatuses(appleAuthorized: providers.isAppleMusicAuthorized())
    }

    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        if let active = player.currentTrack {
            let prefix = player.isPlaying ? "Playing" : "Paused"
            let artistPart = active.artist.isEmpty ? "" : " · \(active.artist)"
            return ModuleGlance(lines: ["\(prefix): \(active.title)\(artistPart)"])
        }
        if let latest = catalog.tracks.first {
            let suffix = catalog.tracks.count == 1 ? "" : " (+\(catalog.tracks.count - 1) more)"
            return ModuleGlance(lines: ["\(latest.title)\(suffix)"])
        }
        return ModuleGlance(lines: ["Add music files or connect a service"], isQuiet: true)
    }

    public func artwork(for track: MusicTrack) async -> Data? {
        guard let artID = track.artworkID else { return nil }
        if let cached = artworkCache[artID] { return cached }
        if let loaded = await vault.loadArtwork(for: track) {
            artworkCache[artID] = loaded
            return loaded
        }
        return nil
    }

    // MARK: Lifecycle

    public func load() async {
        guard phase == .idle || phase == .loading else { return }
        phase = .loading
        catalog = (try? await vault.loadCatalog()) ?? MusicCatalog()
        phase = .ready
    }

    public func reload() async {
        catalog = (try? await vault.loadCatalog()) ?? catalog
        if phase != .ready { phase = .ready }
    }

    public func close() async {
        player.stop()
        activeYouTubeTrack = nil
        queue = []
        artworkCache = [:]
        catalog = MusicCatalog()
        await vault.close()
        phase = .idle
    }

    public func selectTab(_ tab: MusicFilterTab) {
        activeTab = tab
    }

    // MARK: Importing Audio Files

    public func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        var importedCount = 0
        var lastError: String?

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let meta = await ImportedAudioInfo.extract(from: url, fallbackFilename: url.lastPathComponent)
                _ = try await vault.importAudioFile(from: url, metadata: meta)
                importedCount += 1
            } catch {
                lastError = error.localizedDescription
            }
        }

        await reload()
        if let lastError, importedCount == 0 {
            notice = lastError
        } else if let lastError {
            notice = "Imported \(importedCount) file(s). One couldn't be imported: \(lastError)"
        }
    }

    public func toggleLike(_ track: MusicTrack) async {
        guard let index = catalog.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        catalog.tracks[index].isLiked.toggle()
        catalog.tracks[index].updatedAt = Date()
        _ = try? await vault.saveCatalog(catalog)
    }

    public func deleteTrack(_ track: MusicTrack) async {
        let now = Date()
        if player.currentTrack?.id == track.id {
            player.stop()
        }
        queue.removeAll { $0.id == track.id }
        catalog.tracks.removeAll { $0.id == track.id }
        catalog.removedTrackDates[track.id] = now
        for idx in catalog.playlists.indices {
            catalog.playlists[idx].trackIDs.removeAll { $0 == track.id }
            catalog.playlists[idx].updatedAt = now
        }
        if track.source == .upload {
            await vault.deleteUploadedBlobs(for: track)
        }
        _ = try? await vault.saveCatalog(catalog)
    }

    // MARK: Unified Playlists (Mix Any Source)

    public func createPlaylist(name: String, initialTrack: MusicTrack? = nil) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        let playlist = MusicPlaylist(
            name: trimmed,
            trackIDs: initialTrack.map { [$0.id] } ?? [],
            updatedAt: now
        )
        catalog.playlists.insert(playlist, at: 0)
        _ = try? await vault.saveCatalog(catalog)
    }

    public func add(_ track: MusicTrack, to playlistID: UUID) async {
        guard let idx = catalog.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !catalog.playlists[idx].trackIDs.contains(track.id) {
            catalog.playlists[idx].trackIDs.append(track.id)
            catalog.playlists[idx].updatedAt = Date()
            _ = try? await vault.saveCatalog(catalog)
        }
    }

    public func tracks(in playlist: MusicPlaylist) -> [MusicTrack] {
        let map = Dictionary(uniqueKeysWithValues: catalog.tracks.map { ($0.id, $0) })
        return playlist.trackIDs.compactMap { map[$0] }
    }

    public func deletePlaylist(_ playlist: MusicPlaylist) async {
        catalog.playlists.removeAll { $0.id == playlist.id }
        catalog.removedPlaylistDates[playlist.id] = Date()
        _ = try? await vault.saveCatalog(catalog)
    }

    // MARK: Queue & Playback

    public func play(_ track: MusicTrack, in list: [MusicTrack]? = nil) async {
        let sourceList = list ?? filteredTracks
        if let idx = sourceList.firstIndex(where: { $0.id == track.id }) {
            queue = sourceList
            queueIndex = idx
        } else {
            queue = [track]
            queueIndex = 0
        }
        await startPlayback(of: track)
    }

    public func playNext(_ track: MusicTrack) {
        guard !queue.isEmpty else {
            queue = [track]
            queueIndex = 0
            return
        }
        let insertIndex = min(queue.count, queueIndex + 1)
        queue.insert(track, at: insertIndex)
    }

    public func enqueue(_ track: MusicTrack) {
        if queue.isEmpty && player.currentTrack == nil {
            Task { await play(track) }
        } else {
            queue.append(track)
        }
    }

    public func skipNext() async {
        guard !queue.isEmpty else { return }
        if isShuffled, queue.count > 1 {
            let candidates = queue.indices.filter { $0 != queueIndex }
            queueIndex = candidates.randomElement() ?? 0
        } else {
            let next = queueIndex + 1
            if next < queue.count {
                queueIndex = next
            } else if repeatMode == .all {
                queueIndex = 0
            } else {
                player.stop()
                return
            }
        }
        await startPlayback(of: queue[queueIndex])
    }

    public func skipPrevious() async {
        guard !queue.isEmpty else { return }
        if player.currentTime > 3.0 {
            player.seek(to: 0)
            return
        }
        let prev = queueIndex - 1
        if prev >= 0 {
            queueIndex = prev
            await startPlayback(of: queue[queueIndex])
        } else {
            player.seek(to: 0)
        }
    }

    private func advanceAfterFinish() async {
        if repeatMode == .one, let current = player.currentTrack {
            await startPlayback(of: current)
            return
        }
        await skipNext()
    }

    private func startPlayback(of track: MusicTrack) async {
        activeYouTubeTrack = nil
        switch track.source {
        case .upload:
            do {
                let playableURL = try await vault.preparePlayableFile(for: track)
                let art = await artwork(for: track)
                player.playLocalFile(url: playableURL, track: track, artwork: art)
            } catch {
                notice = error.localizedDescription
            }
        case .openSubsonic:
            guard let serverID = track.serverID,
                  let server = catalog.servers.first(where: { $0.id == serverID }) else {
                notice = "The OpenSubsonic server for this track was removed."
                return
            }
            do {
                let streamURL = try subsonic.streamURL(for: track, server: server)
                player.playStream(url: streamURL, track: track, artwork: nil)
            } catch {
                notice = error.localizedDescription
            }
        case .appleMusic:
            do {
                try await providers.playAppleMusicTrack(id: track.sourceID)
            } catch {
                notice = error.localizedDescription
            }
        case .spotify:
            #if os(iOS)
            if let uri = URL(string: track.sourceID) {
                await UIApplication.shared.open(uri)
            }
            #else
            notice = "Open \(track.title) on your paired Spotify app."
            #endif
        case .youTubeMusic:
            player.pause()
            activeYouTubeTrack = track
        }
    }

    // MARK: OpenSubsonic Servers

    public func addOpenSubsonicServer(name: String, baseURL: String, username: String, password: String) async {
        let server = OpenSubsonicServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await subsonic.ping(server: server, password: password)
            try subsonic.savePassword(password, for: server.id)
            var updated = server
            updated.lastSyncedAt = Date()
            updated.updatedAt = Date()
            catalog.servers.append(updated)
            let fetched = try await subsonic.fetchTracks(server: updated, password: password)
            mergeRemoteTracks(fetched, source: .openSubsonic, serverID: updated.id)
            _ = try? await vault.saveCatalog(catalog)
        } catch {
            notice = error.localizedDescription
        }
    }

    public func syncOpenSubsonicServer(_ server: OpenSubsonicServer) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let fetched = try await subsonic.fetchTracks(server: server)
            mergeRemoteTracks(fetched, source: .openSubsonic, serverID: server.id)
            if let idx = catalog.servers.firstIndex(where: { $0.id == server.id }) {
                catalog.servers[idx].lastSyncedAt = Date()
                catalog.servers[idx].updatedAt = Date()
            }
            _ = try? await vault.saveCatalog(catalog)
        } catch {
            notice = error.localizedDescription
        }
    }

    public func removeOpenSubsonicServer(_ server: OpenSubsonicServer) async {
        let now = Date()
        subsonic.deletePassword(for: server.id)
        catalog.servers.removeAll { $0.id == server.id }
        catalog.removedServerDates[server.id] = now
        for track in catalog.tracks where track.serverID == server.id {
            catalog.removedTrackDates[track.id] = now
        }
        catalog.tracks.removeAll { $0.serverID == server.id }
        _ = try? await vault.saveCatalog(catalog)
    }

    // MARK: Connected Streaming Accounts

    public func connectAppleMusic() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let fetched = try await providers.requestAppleMusicAccessAndFetch()
            mergeRemoteTracks(fetched, source: .appleMusic)
            _ = try? await vault.saveCatalog(catalog)
        } catch {
            notice = error.localizedDescription
        }
    }

    public func syncSpotify() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let fetched = try await providers.fetchSpotifySavedTracks()
            mergeRemoteTracks(fetched, source: .spotify)
            _ = try? await vault.saveCatalog(catalog)
        } catch {
            notice = error.localizedDescription
        }
    }

    public func disconnectSpotify() async {
        providers.disconnectSpotify()
        let now = Date()
        for track in catalog.tracks where track.source == .spotify {
            catalog.removedTrackDates[track.id] = now
        }
        catalog.tracks.removeAll { $0.source == .spotify }
        _ = try? await vault.saveCatalog(catalog)
    }

    public func syncYouTubeMusic() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let fetched = try await providers.fetchYouTubeLikedTracks()
            mergeRemoteTracks(fetched, source: .youTubeMusic)
            _ = try? await vault.saveCatalog(catalog)
        } catch {
            notice = error.localizedDescription
        }
    }

    public func disconnectYouTubeMusic() async {
        providers.disconnectYouTubeMusic()
        let now = Date()
        for track in catalog.tracks where track.source == .youTubeMusic {
            catalog.removedTrackDates[track.id] = now
        }
        catalog.tracks.removeAll { $0.source == .youTubeMusic }
        _ = try? await vault.saveCatalog(catalog)
    }

    private func mergeRemoteTracks(_ fetched: [MusicTrack], source: MusicSourceKind, serverID: UUID? = nil) {
        let existingKeys = Dictionary(
            catalog.tracks
                .filter { $0.source == source && (serverID == nil || $0.serverID == serverID) }
                .map { ("\($0.source.rawValue):\($0.sourceID)", $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in fetched {
            let key = "\(item.source.rawValue):\(item.sourceID)"
            if existingKeys[key] == nil {
                catalog.tracks.append(item)
            }
        }
    }
}

/// Registry entry for Music so Universal Search & ModuleRegistry work without cross-module imports.
public struct MusicModule: ContentHandler, ModuleSearcher, ModuleRefresher {
    public let module: ModuleID = .player
    public let kinds: Set<ContentKind> = [.musicCatalog]
    private let vault: MusicVault
    private let refreshHandler: @Sendable () async -> Void

    public init(vault: MusicVault, refresh: @escaping @Sendable () async -> Void = {}) {
        self.vault = vault
        self.refreshHandler = refresh
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let catalog = try await vault.loadCatalog()
        return catalog.tracks.compactMap { track in
            let haystack = "\(track.title) \(track.artist) \(track.album) \(track.source.displayName)".lowercased()
            guard haystack.contains(trimmed) else { return nil }
            return SearchHit(
                module: .player,
                itemID: track.id.uuidString,
                title: track.title,
                detail: "\(track.subtitle) · \(track.source.displayName)",
                date: track.addedAt
            )
        }
    }

    public func refreshAhead() async {
        await refreshHandler()
    }
}
