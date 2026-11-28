import CryptoKit
import Foundation
import Testing
import TotalityCore
@testable import TotalityMusic

private final class MusicMemoryStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    func exists(_ name: String) throws -> Bool { lock.withLock { blobs[name] != nil } }
}

private final class MusicMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func load(_ name: String) throws -> Data? { lock.withLock { items[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { items[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { items.removeValue(forKey: name) } }
}

@MainActor
@Suite("Totality Music")
struct MusicTests {
    private func makeWAVData(seconds: Double = 0.25) -> Data {
        let sampleRate: UInt32 = 22_050
        let sampleCount = Int(Double(sampleRate) * seconds)
        let dataBytes = UInt32(sampleCount * 2)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        var chunkSize = UInt32(36 + dataBytes).littleEndian
        data.append(Data(bytes: &chunkSize, count: 4))
        data.append(contentsOf: "WAVEfmt ".utf8)
        var fmtSize = UInt32(16).littleEndian
        data.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian
        var channels = UInt16(1).littleEndian
        var rate = sampleRate.littleEndian
        var byteRate = (sampleRate * 2).littleEndian
        var blockAlign = UInt16(2).littleEndian
        var bits = UInt16(16).littleEndian
        data.append(Data(bytes: &audioFormat, count: 2))
        data.append(Data(bytes: &channels, count: 2))
        data.append(Data(bytes: &rate, count: 4))
        data.append(Data(bytes: &byteRate, count: 4))
        data.append(Data(bytes: &blockAlign, count: 2))
        data.append(Data(bytes: &bits, count: 2))
        data.append(contentsOf: "data".utf8)
        var dataLen = dataBytes.littleEndian
        data.append(Data(bytes: &dataLen, count: 4))
        data.append(Data(count: Int(dataBytes)))
        return data
    }

    @Test func importsEncryptsPlaysBackAndDeletesUploadedAudioAndPlaylists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("music-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sourceFile = dir.appendingPathComponent("Midnight_Demo.wav")
        let wavBytes = makeWAVData()
        try wavBytes.write(to: sourceFile)

        let store = try FileBlobStore(directory: dir.appendingPathComponent("Vault", isDirectory: true))
        let key = try ContentRootKey.generate()
        let vault = MusicVault(store: store, rootKey: key, cacheDirectory: dir.appendingPathComponent("Cache", isDirectory: true))
        let model = MusicModel(vault: vault)
        await model.load()

        #expect(model.catalog.tracks.isEmpty)
        await model.importFiles([sourceFile])
        #expect(model.catalog.tracks.count == 1)
        let uploaded = try #require(model.catalog.tracks.first)
        #expect(uploaded.title == "Midnight_Demo")
        #expect(uploaded.source == .upload)
        #expect(uploaded.source.privacyBadge == "End-to-end encrypted")

        // Verify stored blob is encrypted ciphertext, not plaintext WAV header.
        let sealedNames = try store.names().filter { $0.hasSuffix(MusicVault.audioSuffix) }
        #expect(sealedNames.count == 1)
        let sealedBytes = try #require(try store.read(sealedNames[0]))
        #expect(!sealedBytes.starts(with: Data("RIFF".utf8)))

        // Verify decryption produces exact original bytes.
        let decryptedURL = try await vault.preparePlayableFile(for: uploaded)
        let decryptedBytes = try Data(contentsOf: decryptedURL)
        #expect(decryptedBytes == wavBytes)

        // Create mixed-source playlist and search through MusicModule.
        let spotifyTrack = MusicTrack(title: "Morning Rain", artist: "K. Tanaka", source: .spotify, sourceID: "spotify:track:123")
        var updated = model.catalog
        updated.tracks.append(spotifyTrack)
        _ = try await vault.saveCatalog(updated)
        await model.reload()

        await model.createPlaylist(name: "Late Night Mix", initialTrack: uploaded)
        let playlist = try #require(model.catalog.playlists.first)
        await model.add(spotifyTrack, to: playlist.id)
        let inPlaylist = model.tracks(in: try #require(model.catalog.playlists.first))
        #expect(inPlaylist.count == 2)

        let module = MusicModule(vault: vault)
        let hits = try await module.search("midnight")
        #expect(hits.count == 1)
        #expect(hits.first?.module == .player)

        // Delete removes blobs cleanly.
        await model.deleteTrack(uploaded)
        #expect((try store.names().filter { $0.hasSuffix(MusicVault.audioSuffix) }).isEmpty)
    }

    @Test func twoUserIsolationUser2CannotDecryptUser1MusicOrReadTokens() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("music-twouser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sourceFile = dir.appendingPathComponent("SecretTrack.wav")
        try makeWAVData().write(to: sourceFile)

        let user1Store = try FileBlobStore(directory: dir.appendingPathComponent("U1", isDirectory: true))
        let user1Key = try ContentRootKey.generate()
        let user1Vault = MusicVault(store: user1Store, rootKey: user1Key)
        let meta = await ImportedAudioInfo.extract(from: sourceFile, fallbackFilename: sourceFile.lastPathComponent)
        let track = try await user1Vault.importAudioFile(from: sourceFile, metadata: meta)

        // User 2 opens User 1's store with User 2's different ContentRootKey.
        let user2Key = try ContentRootKey.generate()
        let user2Vault = MusicVault(store: user1Store, rootKey: user2Key)
        let user2Catalog = try await user2Vault.loadCatalog()
        #expect(user2Catalog.tracks.isEmpty)
        await #expect(throws: Error.self) {
            _ = try await user2Vault.preparePlayableFile(for: track)
        }

        // Keychain accounts cornered by AccountKeyStore isolate User 1 & User 2 OpenSubsonic/Spotify tokens.
        let sharedKeyStore = MusicMemoryKeyStore()
        let u1AccountKeys = AccountKeyStore(sharedKeyStore, account: "user1")
        let u2AccountKeys = AccountKeyStore(sharedKeyStore, account: "user2")
        let serverID = UUID()
        let client1 = OpenSubsonicClient(keyStore: u1AccountKeys)
        let client2 = OpenSubsonicClient(keyStore: u2AccountKeys)
        try client1.savePassword("subsonic-secret-u1", for: serverID)
        #expect(try client1.loadPassword(for: serverID) == "subsonic-secret-u1")
        #expect(try client2.loadPassword(for: serverID) == nil)
    }

    @Test func audioFocusCoordinatorSwitchesCleanlyBetweenReaderAndMusic() async {
        let coordinator = AudioTransportCoordinator()
        var readerPaused = false
        var musicPaused = false
        coordinator.registerPauseHandler(for: .reader) { readerPaused = true }
        coordinator.registerPauseHandler(for: .player) { musicPaused = true }

        coordinator.claimFocus(for: .reader, summary: NowPlayingSummary(module: .reader, title: "Book", badge: .readerListen, isPlaying: true))
        #expect(coordinator.activeModule == .reader)
        #expect(!musicPaused)

        coordinator.claimFocus(for: .player, summary: NowPlayingSummary(module: .player, title: "Song", badge: .uploaded, isPlaying: true))
        #expect(readerPaused)
        #expect(coordinator.activeModule == .player)

        coordinator.claimFocus(for: .reader)
        #expect(musicPaused)
    }

    @Test func openSubsonicAndProviderOAuthURLGenerationAndHonestStatuses() async throws {
        let keyStore = MusicMemoryKeyStore()
        let server = OpenSubsonicServer(name: "Navidrome", baseURL: "https://music.usetotality.invalid", username: "mckay")
        let client = OpenSubsonicClient(keyStore: keyStore) { url in
            let payload: [String: Any] = [
                "subsonic-response": [
                    "status": "ok",
                    "randomSongs": [
                        "song": [
                            [
                                "id": "s-99",
                                "title": "Alpine Ridge",
                                "artist": "Totality Band",
                                "album": "Demos",
                                "duration": 212,
                                "suffix": "flac",
                                "size": 24_000_000,
                            ],
                        ],
                    ],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }

        let songs = try await client.fetchTracks(server: server, password: "demo-password")
        #expect(songs.count == 1)
        #expect(songs[0].title == "Alpine Ridge")
        #expect(songs[0].source == .openSubsonic)
        #expect(songs[0].source.privacyBadge == "Direct to your server")

        try client.savePassword("demo-password", for: server.id)
        let stream = try client.streamURL(for: songs[0], server: server)
        #expect(stream.absoluteString.contains("stream.view"))
        #expect(stream.absoluteString.contains("u=mckay"))
        #expect(!stream.absoluteString.contains("demo-password"))

        let providers = MusicProviderManager(spotifyClientID: "sp-client", googleClientID: "g-client", spotifyStore: keyStore, ytMusicStore: keyStore)
        let pkce = MusicProviderManager.PKCEChallenge()
        let spURL = try providers.spotifyAuthURL(pkce: pkce)
        let ytURL = try providers.youTubeAuthURL(pkce: pkce)
        #expect(spURL.absoluteString.contains("accounts.spotify.com"))
        #expect(ytURL.absoluteString.contains("youtube.readonly"))
        let statuses = providers.connectionStatuses(appleAuthorized: false)
        #expect(statuses.count == 3)
        #expect(statuses.allSatisfy { !$0.isConnected })
    }
}
