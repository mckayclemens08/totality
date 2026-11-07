import CryptoKit
import Foundation
import Testing
@testable import TotalityCore

/// Plays the sealed store in `server/blobs/blobs.mjs`, in memory, one host per test, with each token its
/// own account. `breakAfter` cuts the upload off after that many pieces, the way a lost connection would.
final class FakeSealedStore: URLProtocol, @unchecked Sendable {
    struct Host {
        var accounts: [String: [UUID: (data: Data, done: Bool)]] = [:]
        var limit = 1_000_000
        var breakAfter: Int?
        var pieces = 0
        var methods: [String] = []
        var damage = false
    }

    nonisolated(unsafe) private static var lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String: Host] = [:]

    static func client(token: String = "token-mckay", host: String? = nil, pieceSize: Int = 1_000, setUp: (inout Host) -> Void = { _ in }) -> (SealedStoreClient, String) {
        let name = host ?? "store-\(UUID().uuidString.lowercased()).test"
        lock.withLock {
            var state = hosts[name] ?? Host()
            setUp(&state)
            hosts[name] = state
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeSealedStore.self]
        let client = SealedStoreClient(
            target: SealedStoreTarget(url: "https://\(name)/blobs")!, session: URLSession(configuration: configuration),
            pieceSize: pieceSize, token: { token }
        )
        return (client, name)
    }

    static func state(_ host: String) -> Host { lock.withLock { hosts[host]! } }
    static func change(_ host: String, _ work: (inout Host) -> Void) { lock.withLock { work(&hosts[host]!) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func body() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let method = request.httpMethod ?? "GET"
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        let sent = body()
        let (status, headers, data, cut): (Int, [String: String], Data, Bool) = Self.lock.withLock {
            var state = Self.hosts[host]!
            defer { Self.hosts[host] = state }
            state.methods.append(method)
            guard let token, token.hasPrefix("token-") else { return (401, [:], Data(), false) }
            var blobs = state.accounts[token] ?? [:]
            defer { state.accounts[token] = blobs }
            let last = url.lastPathComponent
            let used = blobs.values.reduce(0) { $0 + $1.data.count }
            if last == "usage" { return (200, [:], try! JSONSerialization.data(withJSONObject: ["used": used, "limit": state.limit]), false) }
            if last == "list" {
                let listed = blobs.filter(\.value.done).map { ["id": $0.key.uuidString.lowercased(), "size": $0.value.data.count, "stored": "2026-11-05T10:00:00Z"] as [String: Any] }
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["blobs": listed, "used": used, "limit": state.limit]), false)
            }
            guard let id = UUID(uuidString: last) else { return (404, [:], Data(), false) }
            let held = blobs[id]
            switch method {
            case "HEAD":
                guard let held else { return (404, [:], Data(), false) }
                return held.done
                    ? (200, ["Blob-State": "done", "Blob-Size": String(held.data.count)], Data(), false)
                    : (200, ["Blob-State": "uploading", "Upload-Offset": String(held.data.count)], Data(), false)
            case "GET":
                guard let held, held.done else { return (404, [:], Data(), false) }
                return (200, [:], held.data, false)
            case "DELETE":
                blobs[id] = nil
                return (204, [:], Data(), false)
            case "PATCH":
                if held?.done == true { return (409, ["Blob-State": "done"], Data(), false) }
                let offset = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? -1
                let have = held?.data.count ?? 0
                guard offset == have else { return (409, ["Upload-Offset": String(have)], Data(), false) }
                guard used + sent.count <= state.limit else { return (507, [:], Data(), false) }
                if let breakAfter = state.breakAfter, state.pieces >= breakAfter { return (0, [:], Data(), true) }
                state.pieces += 1
                var piece = sent
                if state.damage, offset == 0, !piece.isEmpty { piece[0] ^= 0xff }
                blobs[id] = ((held?.data ?? Data()) + piece, false)
                return (204, ["Upload-Offset": String(have + piece.count)], Data(), false)
            case "POST":
                if held?.done == true { return (409, [:], Data(), false) }
                guard let held else { return (404, [:], Data(), false) }
                let asked = try! JSONSerialization.jsonObject(with: sent) as! [String: Any]
                let hash = SHA256.hash(data: held.data).map { String(format: "%02x", $0) }.joined()
                guard asked["size"] as? Int == held.data.count, asked["sha256"] as? String == hash else { return (400, [:], Data(), false) }
                blobs[id] = (held.data, true)
                return (201, [:], Data(), false)
            default:
                return (405, [:], Data(), false)
            }
        }
        if cut {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func sealedBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

@Suite struct SealedStoreTargetTests {
    @Test func theTargetIsConfigurationAndOnlyHTTPS() {
        #expect(SealedStoreTarget.standard.url.absoluteString == "https://usetotality.com/blobs/")
        #expect(SealedStoreTarget(url: "https://home.example/blobs")?.url.absoluteString == "https://home.example/blobs/")
        for bad in [nil, "", "http://usetotality.com/blobs/", "https:///blobs", "https://a.example/blobs?x=1", "https://me:pw@a.example/", "ftp://a.example/"] {
            #expect(SealedStoreTarget(url: bad) == nil, "\(bad ?? "nil")")
        }
        // An app built without the setting, or with it left blank, uses the standard target.
        #expect(SealedStoreTarget.fromBundle(Bundle(for: FakeSealedStore.self)) == .standard)
    }

    @Test func aRowNamesTheBlobAndNeverTheServer() {
        let owner = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        let blob = UUID()
        let key = SealedBlobKey.key(owner: owner, blob: blob)
        #expect(key == "\(owner)/sealed/\(blob.uuidString.lowercased())")
        #expect(SealedBlobKey.blob(in: key, owner: owner) == blob)
        #expect(SealedBlobKey.isSealed(key))
        // Another owner's key, a Supabase path, and anything odd are never taken for one.
        #expect(SealedBlobKey.blob(in: key, owner: other) == nil)
        #expect(SealedBlobKey.blob(in: "\(owner)/\(blob.uuidString.lowercased())/abc.body", owner: owner) == nil)
        #expect(!SealedBlobKey.isSealed("\(owner)/\(blob.uuidString.lowercased())/abc.body"))
        #expect(SealedBlobKey.blob(in: "\(owner)/sealed/\(blob.uuidString)", owner: owner) == nil)
        #expect(SealedBlobKey.blob(in: "\(owner)/sealed/../x", owner: owner) == nil)
    }

    @Test func oneBodyAlwaysGetsTheSameBlob() {
        let owner = UUID().uuidString.lowercased()
        let item = UUID()
        let blob = SealedBlobKey.blob(owner: owner, item: item, bodyHash: "ab12")
        #expect(SealedBlobKey.blob(owner: owner, item: item, bodyHash: "ab12") == blob)
        #expect(SealedBlobKey.blob(owner: owner, item: item, bodyHash: "ab13") != blob)
        #expect(SealedBlobKey.blob(owner: UUID().uuidString.lowercased(), item: item, bodyHash: "ab12") != blob)
    }
}

@Suite struct SealedStoreClientTests {
    @Test func storesInPiecesAndReadsBack() async throws {
        let (store, host) = FakeSealedStore.client(pieceSize: 1_000)
        let blob = sealedBytes(3_500)
        let id = UUID()
        try await store.put(blob, as: id)
        #expect(try await store.get(id) == blob)
        #expect(try await store.size(of: id) == 3_500)
        #expect(FakeSealedStore.state(host).methods.filter { $0 == "PATCH" }.count == 4)
        #expect(try await store.list() == [SealedStoreEntry(id: id, size: 3_500)])
        #expect(try await store.usage() == SealedStoreUsage(used: 3_500, limit: 1_000_000))
        #expect(try await store.get(UUID()) == nil)
    }

    @Test func aCutOffUploadPicksUpWhereItStopped() async throws {
        let (store, host) = FakeSealedStore.client(pieceSize: 1_000) { $0.breakAfter = 2 }
        let blob = sealedBytes(5_000)
        let id = UUID()
        await #expect(throws: SealedStoreError.offline) { try await store.put(blob, as: id) }
        #expect(try await store.get(id) == nil)
        FakeSealedStore.change(host) { $0.breakAfter = nil; $0.methods = [] }
        try await store.put(blob, as: id)
        #expect(try await store.get(id) == blob)
        // Only the three pieces that hadn't arrived went again.
        #expect(FakeSealedStore.state(host).methods.filter { $0 == "PATCH" }.count == 3)
    }

    @Test func storingAFinishedBlobAgainChangesNothing() async throws {
        let (store, host) = FakeSealedStore.client()
        let blob = sealedBytes(1_500)
        let id = UUID()
        try await store.put(blob, as: id)
        FakeSealedStore.change(host) { $0.methods = [] }
        try await store.put(blob, as: id)
        #expect(FakeSealedStore.state(host).methods == ["HEAD"])
        await #expect(throws: SealedStoreError.mismatch) { try await store.put(sealedBytes(10), as: id) }
    }

    @Test func damageOnTheWayIsNeverKept() async throws {
        let (store, host) = FakeSealedStore.client { $0.damage = true }
        let id = UUID()
        await #expect(throws: SealedStoreError.mismatch) { try await store.put(sealedBytes(2_000), as: id) }
        #expect(try await store.get(id) == nil)
        #expect(FakeSealedStore.state(host).accounts["token-mckay"]?[id] == nil)
    }

    @Test func aFullAccountSaysSo() async throws {
        let (store, _) = FakeSealedStore.client { $0.limit = 1_000 }
        await #expect(throws: SealedStoreError.full) { try await store.put(sealedBytes(2_500), as: UUID()) }
    }

    @Test func nothingWorksSignedOut() async throws {
        let (store, _) = FakeSealedStore.client(token: "nobody")
        await #expect(throws: SealedStoreError.signedOut) { try await store.get(UUID()) }
        await #expect(throws: SealedStoreError.signedOut) { try await store.put(sealedBytes(10), as: UUID()) }
        let failing = SealedStoreClient(target: .standard, token: { throw CancellationError() })
        await #expect(throws: SealedStoreError.signedOut) { try await failing.usage() }
    }

    @Test func anEmptyBlobIsRefusedBeforeItLeaves() async throws {
        let (store, host) = FakeSealedStore.client()
        await #expect(throws: SealedStoreError.mismatch) { try await store.put(Data(), as: UUID()) }
        #expect(FakeSealedStore.state(host).methods.isEmpty)
    }

    /// The client's half of the two-user test. The server's half, with direct requests, is in
    /// `server/blobs/blobs.test.mjs`.
    @Test func user2SeesNoneOfUser1sBlobs() async throws {
        let (mine, host) = FakeSealedStore.client(token: "token-mckay")
        let (theirs, _) = FakeSealedStore.client(token: "token-dana", host: host)
        let id = UUID()
        let blob = sealedBytes(1_200)
        try await mine.put(blob, as: id)
        #expect(try await theirs.get(id) == nil)
        #expect(try await theirs.size(of: id) == nil)
        #expect(try await theirs.list().isEmpty)
        try await theirs.delete(id)
        #expect(try await mine.get(id) == blob)
    }
}
