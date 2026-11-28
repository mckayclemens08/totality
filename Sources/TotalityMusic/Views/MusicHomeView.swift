import AuthenticationServices
import SwiftUI
import TotalityCore
import TotalityUI
import UniformTypeIdentifiers
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Full Music screen (`ModuleID.player`): encrypted uploads, OpenSubsonic servers, mixed-source
/// playlists, Apple Music / Spotify / YouTube Music connections, mini-player, and Now Playing sheet.
public struct MusicHomeView: View {
    @Bindable private var model: MusicModel
    private let onClose: (() -> Void)?

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var showingImporter = false
    @State private var showingAddServer = false
    @State private var showingSpotifySetup = false
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var pendingTrackForPlaylist: MusicTrack?
    @State private var selectedPlaylist: MusicPlaylist?
    @State private var showingNowPlaying = false
    @State private var oauthPKCE: MusicProviderManager.PKCEChallenge?

    public init(model: MusicModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(spacing: 0) {
                header(theme: theme)
                tabBar(theme: theme)
                Divider().overlay(theme.shadowDark.color.opacity(0.18))

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        switch model.activeTab {
                        case .library:
                            libraryContent(theme: theme)
                        case .playlists:
                            playlistsContent(theme: theme)
                        case .uploads:
                            uploadsAndServersContent(theme: theme)
                        case .connections:
                            connectionsContent(theme: theme)
                        }
                    }
                    .padding(Space.s4)
                }

                if let track = model.player.currentTrack {
                    miniPlayer(track: track, theme: theme)
                }
            }
            .background(theme.bg.color)
            .navigationBarBackButtonHidden(true)
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: Self.supportedAudioTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task { await model.importFiles(urls) }
                }
            }
            .sheet(isPresented: $showingAddServer) {
                AddOpenSubsonicSheet(model: model) { showingAddServer = false }
            }
            .sheet(isPresented: $showingSpotifySetup) {
                SpotifySetupSheet(model: model) { shouldLaunch in
                    showingSpotifySetup = false
                    if shouldLaunch { startSpotifyOAuth() }
                }
            }
            .sheet(isPresented: $showingNowPlaying) {
                NowPlayingSheet(model: model) { showingNowPlaying = false }
            }
            .sheet(item: $selectedPlaylist) { playlist in
                PlaylistDetailSheet(model: model, playlist: playlist) {
                    selectedPlaylist = nil
                }
            }
            .sheet(item: Bindable(model).activeYouTubeTrack) { track in
                YouTubeTrackPlayerSheet(track: track) {
                    model.activeYouTubeTrack = nil
                }
            }
            .sheet(item: $pendingTrackForPlaylist) { track in
                PlaylistPickerSheet(model: model, track: track) {
                    pendingTrackForPlaylist = nil
                }
            }
            .alert("New Playlist", isPresented: $showingNewPlaylist) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create") {
                    let name = newPlaylistName
                    newPlaylistName = ""
                    Task { await model.createPlaylist(name: name) }
                }
            }
            .alert("Music", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("OK", role: .cancel) { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
        }
        .edgeSwipeBack(onClose)
        .task { await model.load() }
        .onChange(of: model.requestedItemID) { _, requested in
            guard let requested, let uuid = UUID(uuidString: requested),
                  let track = model.catalog.tracks.first(where: { $0.id == uuid }) else { return }
            model.requestedItemID = nil
            Task { await model.play(track) }
        }
    }

    private static var supportedAudioTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        for ext in ["flac", "alac", "m4a", "opus", "ogg"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    private func header(theme: Theme) -> some View {
        HStack(spacing: Space.s2) {
            if let onClose {
                HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
            }
            Text("Music")
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            Spacer(minLength: 0)
            AskTotalityButton(context: AIAskContext(id: "music.home", module: .player, title: "Music"))
            HeaderButton("Add audio files", systemImage: "plus") {
                showingImporter = true
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
    }

    private func tabBar(theme: Theme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(MusicFilterTab.allCases) { tab in
                    let isSelected = model.activeTab == tab
                    HeaderPill(tab.rawValue, isProminent: isSelected) {
                        model.selectTab(tab)
                    }
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
        }
    }

    // MARK: Library Tab

    @ViewBuilder
    private func libraryContent(theme: Theme) -> some View {
        TextField("Search songs, artists, or albums", text: Bindable(model).searchQuery)
            .font(Typeface.body)
            .foregroundStyle(theme.textPrimary.color)
            .raisedField(.line)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                HeaderPill("All", isProminent: model.selectedSourceFilter == nil) {
                    model.selectedSourceFilter = nil
                }
                ForEach(MusicSourceKind.allCases, id: \.self) { kind in
                    HeaderPill(kind.displayName, systemImage: kind.systemImage, isProminent: model.selectedSourceFilter == kind) {
                        model.selectedSourceFilter = (model.selectedSourceFilter == kind) ? nil : kind
                    }
                }
            }
        }

        if model.isImporting || model.isSyncing {
            HStack(spacing: Space.s3) {
                ProgressView()
                Text(model.isImporting ? "Encrypting and importing audio…" : "Syncing library…")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .itemCard()
        }

        let tracks = model.filteredTracks
        if tracks.isEmpty {
            VStack(alignment: .leading, spacing: Space.s3) {
                Image(systemName: "music.note.list")
                    .font(Typeface.title)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityHidden(true)
                Text(model.catalog.tracks.isEmpty ? "Your Music library is empty" : "No matching tracks")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text("Upload audio files (FLAC, MP3, M4A, WAV — end-to-end encrypted), add an OpenSubsonic server, or connect Apple Music, Spotify, or YouTube Music.")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s2) {
                    HeaderPill("Upload files", systemImage: "square.and.arrow.up", isProminent: true) {
                        showingImporter = true
                    }
                    HeaderPill("Connections") {
                        model.selectTab(.connections)
                    }
                }
            }
            .itemCard()
        } else {
            VStack(spacing: Space.s3) {
                ForEach(tracks) { track in
                    trackRow(track, theme: theme)
                }
            }
        }
    }

    private func trackRow(_ track: MusicTrack, theme: Theme) -> some View {
        let isActive = model.player.currentTrack?.id == track.id
        return HStack(spacing: Space.s3) {
            Button {
                Task {
                    if isActive {
                        model.player.togglePause()
                    } else {
                        await model.play(track)
                    }
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(isActive ? theme.accent.color : theme.highlight.color)
                        .frame(width: Space.s7, height: Space.s7)
                    Image(systemName: (isActive && model.player.isPlaying) ? "pause.fill" : track.source.systemImage)
                        .font(Typeface.callout.weight(.semibold))
                        .foregroundStyle(isActive ? theme.accentOn.color : theme.accent.color)
                }
            }
            .buttonStyle(SoftPress())

            Button {
                Task { await model.play(track) }
            } label: {
                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                    Text(track.title)
                        .font(Typeface.headline)
                        .foregroundStyle(isActive ? theme.accent.color : theme.textPrimary.color)
                        .lineLimit(1)
                    Text("\(track.subtitle) · \(track.formatLabel)")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                    Text(track.source.privacyBadge)
                        .font(Typeface.micro)
                        .foregroundStyle(track.source == .upload ? theme.success.color : theme.textSecondary.color)
                }
                Spacer(minLength: 0)
                Text(track.formattedDuration)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .monospacedDigit()
            }
            .buttonStyle(.plain)

            Menu {
                AskTotalityMenuButton(context: AIAskContext(
                    id: track.id.uuidString,
                    module: .player,
                    title: track.title,
                    detail: "\(track.subtitle) · \(track.source.displayName)",
                    body: "Format: \(track.formatLabel), Privacy: \(track.source.privacyBadge), Duration: \(track.formattedDuration)"
                ))
                Button("Play Next", systemImage: "text.insert") { model.playNext(track) }
                Button("Add to Queue", systemImage: "text.append") { model.enqueue(track) }
                Button("Add to Playlist", systemImage: "music.note.list") { pendingTrackForPlaylist = track }
                Button(track.isLiked ? "Unlike" : "Favorite", systemImage: track.isLiked ? "heart.slash" : "heart") {
                    Task { await model.toggleLike(track) }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await model.deleteTrack(track) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s6, height: Space.s6)
                    .contentShape(Rectangle())
            }
        }
        .itemCard()
    }

    // MARK: Playlists Tab

    @ViewBuilder
    private func playlistsContent(theme: Theme) -> some View {
        HStack {
            Text("Mixed-source playlists")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Spacer(minLength: 0)
            HeaderPill("New Playlist", systemImage: "plus", isProminent: true) {
                showingNewPlaylist = true
            }
        }

        if model.catalog.playlists.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("No playlists yet")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text("Create a playlist to combine encrypted files you uploaded with tracks from OpenSubsonic, Apple Music, Spotify, and YouTube Music.")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .itemCard()
        } else {
            ForEach(model.catalog.playlists) { playlist in
                let tracks = model.tracks(in: playlist)
                Button {
                    selectedPlaylist = playlist
                } label: {
                    HStack(spacing: Space.s3) {
                        Image(systemName: "music.note.list")
                            .font(Typeface.title)
                            .foregroundStyle(theme.accent.color)
                        VStack(alignment: .leading, spacing: Space.s1 / 2) {
                            Text(playlist.name)
                                .font(Typeface.headline)
                                .foregroundStyle(theme.textPrimary.color)
                            Text(tracks.count == 1 ? "1 track" : "\(tracks.count) tracks")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    .itemCard()
                }
                .buttonStyle(SoftPress())
            }
        }
    }

    // MARK: Uploads & OpenSubsonic Servers Tab

    @ViewBuilder
    private func uploadsAndServersContent(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Upload your own audio")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Files are encrypted client-side in 1 MiB chunks (`ContentCipher` / `ChunkedCipher`) before storage and stripped of outside metadata.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HeaderPill("Choose Audio Files", systemImage: "folder.badge.plus", isProminent: true) {
                showingImporter = true
            }
        }
        .itemCard()

        HStack {
            Text("OpenSubsonic & Navidrome")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Spacer(minLength: 0)
            HeaderPill("Add Server", systemImage: "plus") {
                showingAddServer = true
            }
        }

        if model.catalog.servers.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("No Open-Source Music Servers")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text("Connect Navidrome, Gonic, Airsonic, or Jellyfin Subsonic servers directly from your device.")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .itemCard()
        } else {
            ForEach(model.catalog.servers) { server in
                VStack(alignment: .leading, spacing: Space.s2) {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.s1 / 2) {
                            Text(server.name)
                                .font(Typeface.headline)
                                .foregroundStyle(theme.textPrimary.color)
                            Text("\(server.baseURL) · \(server.username)")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                        Spacer(minLength: 0)
                        HeaderPill("Sync") {
                            Task { await model.syncOpenSubsonicServer(server) }
                        }
                        HeaderPill("Remove") {
                            Task { await model.removeOpenSubsonicServer(server) }
                        }
                    }
                    Text("Direct to your server · Password stored only in Keychain")
                        .font(Typeface.micro)
                        .foregroundStyle(theme.success.color)
                }
                .itemCard()
            }
        }
    }

    // MARK: Connections Tab

    @ViewBuilder
    private func connectionsContent(theme: Theme) -> some View {
        Text("Connected accounts stay sealed in your Keychain on this device. Totality never proxies outside audio through its servers.")
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)

        ForEach(model.connections, id: \.provider) { status in
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Image(systemName: status.provider.systemImage)
                        .foregroundStyle(theme.accent.color)
                    Text(status.provider.displayName)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                    Spacer(minLength: 0)
                    Text(status.isConnected ? "Connected" : "Not connected")
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(status.isConnected ? theme.success.color : theme.textSecondary.color)
                }
                Text("Scopes: \(status.scopesDescription)")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                if let note = status.note {
                    Text(note)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                connectionButtons(status, theme: theme)
            }
            .itemCard()
        }
    }

    @ViewBuilder
    private func connectionButtons(_ status: StreamingConnectionStatus, theme: Theme) -> some View {
        switch status.provider {
        case .appleMusic:
            HeaderPill(status.isConnected ? "Refresh Apple Music" : "Connect Apple Music", isProminent: !status.isConnected) {
                Task { await model.connectAppleMusic() }
            }
        case .spotify:
            HStack(spacing: Space.s2) {
                if status.isConnected {
                    HeaderPill("Sync Spotify", isProminent: true) {
                        Task { await model.syncSpotify() }
                    }
                    HeaderPill("Disconnect") {
                        Task { await model.disconnectSpotify() }
                    }
                } else {
                    HeaderPill("Connect Spotify", isProminent: true) {
                        if model.providers.spotifyClientID == nil {
                            showingSpotifySetup = true
                        } else {
                            startSpotifyOAuth()
                        }
                    }
                }
            }
        case .youTubeMusic:
            HStack(spacing: Space.s2) {
                if status.isConnected {
                    HeaderPill("Sync YouTube Music", isProminent: true) {
                        Task { await model.syncYouTubeMusic() }
                    }
                    HeaderPill("Disconnect") {
                        Task { await model.disconnectYouTubeMusic() }
                    }
                } else {
                    HeaderPill("Connect YouTube Music", isProminent: true) {
                        startYouTubeOAuth()
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func startSpotifyOAuth() {
        guard model.providers.spotifyClientID != nil else {
            showingSpotifySetup = true
            return
        }
        startOAuth(callbackScheme: MusicProviderManager.callbackScheme, makeURL: model.providers.spotifyAuthURL) { code, verifier in
            _ = try await model.providers.exchangeSpotifyCode(code, verifier: verifier)
            await model.syncSpotify()
        }
    }

    private func startYouTubeOAuth() {
        startOAuth(callbackScheme: model.providers.youTubeCallbackScheme, makeURL: model.providers.youTubeAuthURL) { code, verifier in
            _ = try await model.providers.exchangeYouTubeCode(code, verifier: verifier)
            await model.syncYouTubeMusic()
        }
    }

    private func startOAuth(
        callbackScheme: String,
        makeURL: (MusicProviderManager.PKCEChallenge) throws -> URL,
        onExchange: @escaping @MainActor (String, String) async throws -> Void
    ) {
        let pkce = MusicProviderManager.PKCEChallenge()
        oauthPKCE = pkce
        do {
            let authURL = try makeURL(pkce)
            Task { @MainActor in
                do {
                    let callbackURL = try await webAuthenticationSession.authenticate(
                        using: authURL,
                        callbackURLScheme: callbackScheme
                    )
                    guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value else { return }
                    try await onExchange(code, pkce.verifier)
                } catch {
                    model.notice = error.localizedDescription
                }
            }
        } catch {
            model.notice = error.localizedDescription
        }
    }

    // MARK: Mini Player

    private func miniPlayer(track: MusicTrack, theme: Theme) -> some View {
        Button {
            showingNowPlaying = true
        } label: {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(theme.accent.color)
                        .frame(width: max(0, proxy.size.width * model.player.progress), height: 2)
                }
                .frame(height: 2)

                HStack(spacing: Space.s3) {
                    Image(systemName: track.source.systemImage)
                        .foregroundStyle(theme.accent.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(Typeface.callout.weight(.semibold))
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                        Text("\(track.subtitle) · \(track.source.privacyBadge)")
                            .font(Typeface.micro)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.player.togglePause()
                    } label: {
                        Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                            .frame(width: Space.s6, height: Space.s6)
                    }
                    .buttonStyle(SoftPress())

                    Button {
                        Task { await model.skipNext() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textPrimary.color)
                            .frame(width: Space.s6, height: Space.s6)
                    }
                    .buttonStyle(SoftPress())
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
            }
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Supporting Sheets

private struct SpotifySetupSheet: View {
    @Bindable var model: MusicModel
    let onFinish: (Bool) -> Void
    @State private var clientID = ""
    @State private var copiedRedirect = false

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("Spotify requires a free Developer App Client ID so playback & library tokens stay directly between your iPhone and Spotify.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("1. In developer.spotify.com/dashboard, add Redirect URI:")
                            .font(Typeface.callout.weight(.semibold))
                            .foregroundStyle(theme.textPrimary.color)
                        HStack {
                            Text(MusicProviderManager.spotifyRedirectURI)
                                .font(Typeface.caption.monospaced())
                                .foregroundStyle(theme.textPrimary.color)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            HeaderPill(copiedRedirect ? "Copied" : "Copy") {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = MusicProviderManager.spotifyRedirectURI
                                #elseif canImport(AppKit)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(MusicProviderManager.spotifyRedirectURI, forType: .string)
                                #endif
                                copiedRedirect = true
                            }
                        }
                    }
                    .itemCard()

                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("2. Paste your Spotify Client ID (saved in Keychain):")
                            .font(Typeface.callout.weight(.semibold))
                            .foregroundStyle(theme.textPrimary.color)
                        TextField("e.g. 1a2b3c4d5e6f...", text: $clientID)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .raisedField(.line)
                    }
                    .itemCard()

                    HeaderPill("Save & Connect Spotify", isProminent: true, expands: true) {
                        do {
                            try model.providers.saveSpotifyClientID(clientID)
                            onFinish(true)
                        } catch {
                            model.notice = error.localizedDescription
                            onFinish(false)
                        }
                    }
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Connect Spotify")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(false) }
                }
            }
        }
    }
}

private struct AddOpenSubsonicSheet: View {
    @Bindable var model: MusicModel
    let onDone: () -> Void

    @State private var name = ""
    @State private var url = "https://"
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            Form {
                Section("OpenSubsonic / Navidrome Server") {
                    TextField("Server Name (e.g. Home Navidrome)", text: $name)
                    TextField("https://music.example.com", text: $url)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("Password (sealed in Keychain)", text: $password)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg.color)
            .navigationTitle("Add Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        Task {
                            await model.addOpenSubsonicServer(name: name, baseURL: url, username: username, password: password)
                            onDone()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }
            }
        }
    }
}

private struct NowPlayingSheet: View {
    @Bindable var model: MusicModel
    let onClose: () -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(spacing: Space.s4) {
                Spacer(minLength: 0)
                if let track = model.player.currentTrack {
                    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .fill(theme.highlight.color)
                        .frame(width: 220, height: 220)
                        .overlay {
                            Image(systemName: track.source.systemImage)
                                .font(.system(size: 64))
                                .foregroundStyle(theme.accent.color)
                        }
                        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))

                    VStack(spacing: Space.s1) {
                        Text(track.title)
                            .font(Typeface.title)
                            .foregroundStyle(theme.textPrimary.color)
                            .multilineTextAlignment(.center)
                        Text(track.subtitle)
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                        Text("\(track.formatLabel) · \(track.source.privacyBadge)")
                            .font(Typeface.caption.weight(.medium))
                            .foregroundStyle(theme.success.color)
                    }

                    Slider(
                        value: Binding(
                            get: { model.player.progress },
                            set: { model.player.seek(to: $0) }
                        ),
                        in: 0...1
                    )
                    .tint(theme.accent.color)

                    HStack {
                        Text(formatTime(model.player.currentTime))
                        Spacer()
                        Text(formatTime(model.player.duration))
                    }
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .monospacedDigit()

                    HStack(spacing: Space.s5) {
                        Button {
                            model.isShuffled.toggle()
                        } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(model.isShuffled ? theme.accent.color : theme.textSecondary.color)
                        }
                        .buttonStyle(SoftPress())

                        Button {
                            Task { await model.skipPrevious() }
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                                .foregroundStyle(theme.textPrimary.color)
                        }
                        .buttonStyle(SoftPress())

                        Button {
                            model.player.togglePause()
                        } label: {
                            Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundStyle(theme.accentOn.color)
                                .frame(width: 64, height: 64)
                                .background(theme.accent.color, in: Circle())
                        }
                        .buttonStyle(SoftPress())

                        Button {
                            Task { await model.skipNext() }
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                                .foregroundStyle(theme.textPrimary.color)
                        }
                        .buttonStyle(SoftPress())

                        Button {
                            model.repeatMode = switch model.repeatMode {
                            case .off: .all
                            case .all: .one
                            case .one: .off
                            }
                        } label: {
                            Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                                .foregroundStyle(model.repeatMode == .off ? theme.textSecondary.color : theme.accent.color)
                        }
                        .buttonStyle(SoftPress())
                    }

                    HStack(spacing: Space.s3) {
                        Menu {
                            ForEach(MusicAudioPlayer.speeds, id: \.self) { rate in
                                Button("\(rate.formatted(.number.precision(.fractionLength(0...2))))×") {
                                    model.player.setSpeed(rate)
                                }
                            }
                        } label: {
                            HeaderPill("Speed: \(model.player.speed.formatted(.number.precision(.fractionLength(0...2))))×") {}
                        }
                        AskTotalityButton(context: AIAskContext(
                            id: track.id.uuidString,
                            module: .player,
                            title: track.title,
                            detail: track.subtitle
                        ))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s5)
            .background(theme.bg.color)
            .navigationTitle("Now Playing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PlaylistDetailSheet: View {
    @Bindable var model: MusicModel
    let playlist: MusicPlaylist
    let onClose: () -> Void

    var body: some View {
        let theme = Theme.current
        let tracks = model.tracks(in: playlist)
        NavigationStack {
            List {
                ForEach(tracks) { track in
                    Button {
                        Task { await model.play(track, in: tracks) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(Typeface.headline)
                                .foregroundStyle(theme.textPrimary.color)
                            Text("\(track.subtitle) · \(track.source.displayName)")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg.color)
            .navigationTitle(playlist.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Delete", role: .destructive) {
                        Task {
                            await model.deletePlaylist(playlist)
                            onClose()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

private struct PlaylistPickerSheet: View {
    @Bindable var model: MusicModel
    let track: MusicTrack
    let onDone: () -> Void
    @State private var customName = ""

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            List {
                Section("New Playlist") {
                    HStack {
                        TextField("Playlist name", text: $customName)
                        Button("Add") {
                            Task {
                                await model.createPlaylist(name: customName, initialTrack: track)
                                onDone()
                            }
                        }
                        .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !model.catalog.playlists.isEmpty {
                    Section("Existing Playlists") {
                        ForEach(model.catalog.playlists) { playlist in
                            Button(playlist.name) {
                                Task {
                                    await model.add(track, to: playlist.id)
                                    onDone()
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg.color)
            .navigationTitle("Add to Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
            }
        }
    }
}

/// TOS-compliant embedded YouTube Music player using Google's official iframe embed (`youtube-nocookie.com`).
private struct YouTubeTrackPlayerSheet: View {
    let track: MusicTrack
    let onClose: () -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(spacing: Space.s3) {
                YouTubeEmbedWebView(videoID: track.sourceID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Streamed via YouTube embedded player under your Google account.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.bottom, Space.s3)
            }
            .background(theme.bg.color)
            .navigationTitle(track.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
        }
    }
}

#if os(iOS)
private struct YouTubeEmbedWebView: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        return WKWebView(frame: .zero, configuration: config)
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if let url = URL(string: "https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1") {
            if view.url != url { view.load(URLRequest(url: url)) }
        }
    }
}
#elseif os(macOS)
private struct YouTubeEmbedWebView: NSViewRepresentable {
    let videoID: String

    func makeNSView(context: Context) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if let url = URL(string: "https://www.youtube-nocookie.com/embed/\(videoID)") {
            if view.url != url { view.load(URLRequest(url: url)) }
        }
    }
}
#endif
