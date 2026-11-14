import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

private let clientID = "204117362514-q4f8kd2lmz0x7r1t9vbn3c6hwyas5pe0.apps.googleusercontent.com"
let driveOwner = "mckay.clemens@gmail.com"

/// Keeps Keychain items in memory, so a test's Google connections never touch the real Keychain.
final class MemoryKeys: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func load(_ name: String) throws -> Data? { lock.withLock { items[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { items[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { items.removeValue(forKey: name) } }
}

/// Stands in for Google: the token endpoint, the revoke endpoint, and Drive's file listings.
final class FakeDrive: GoogleHTTP, @unchecked Sendable {
    private let lock = NSLock()
    /// Each parent's children, as Drive lists them. "root" is My Drive, "shared" is Shared with me.
    var children: [String: [[String: Any]]] = [:]
    var status = 200
    var errorBody: [String: Any] = ["error": ["message": "no"]]
    private(set) var asked: [URLComponents] = []
    private(set) var revoked = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url == GoogleSignIn.tokenURL { return answer(200, ["access_token": "ya29.drive"]) }
        if url == GoogleSignIn.revokeURL {
            lock.withLock { revoked += 1 }
            return answer(200, [:])
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.drive")
        #expect(url.host == "www.googleapis.com")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        lock.withLock { asked.append(components) }
        if status != 200 { return answer(status, errorBody) }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        #expect(components.path == "/drive/v3/files")
        let q = try #require(query["q"])
        let parent: String
        if q.hasPrefix("sharedWithMe = true") {
            parent = "shared"
        } else {
            let quoted = try #require(q.split(separator: "'").first)
            parent = String(quoted)
        }
        var files = children[parent] ?? []
        if q.contains("mimeType = '\(DriveEntry.folderMime)'") {
            files = files.filter { $0["mimeType"] as? String == DriveEntry.folderMime }
        }
        // Two pages, to check paging.
        if query["pageToken"] == nil, files.count > 1 {
            return answer(200, ["files": Array(files.prefix(1)), "nextPageToken": "page-2"])
        }
        return answer(200, ["files": query["pageToken"] == nil ? files : Array(files.dropFirst())])
    }

    var listings: [URLComponents] { lock.withLock { asked } }

    private func answer(_ status: Int, _ body: [String: Any]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: GoogleSignIn.tokenURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

func driveFolder(_ id: String, _ name: String) -> [String: Any] {
    ["id": id, "name": name, "mimeType": DriveEntry.folderMime, "modifiedTime": "2026-11-12T18:04:11.512Z", "capabilities": ["canEdit": true]]
}

func driveFile(_ id: String, _ name: String, mime: String, size: Int? = nil, version: String = "7") -> [String: Any] {
    var file: [String: Any] = ["id": id, "name": name, "mimeType": mime, "modifiedTime": "2026-11-12T18:04:11Z", "version": version, "capabilities": ["canEdit": true]]
    if let size { file["size"] = String(size) }
    return file
}

struct DriveSetup {
    let drive: GoogleDrive
    let accounts: GoogleAccounts
    let store: MemoryBlobStore
    let rootKey: ContentRootKey
}

func makeDrive(
    _ fake: FakeDrive, keys: MemoryKeys = MemoryKeys(), store: MemoryBlobStore = MemoryBlobStore(),
    rootKey: ContentRootKey? = nil, granted: Set<String>? = [DriveAPI.scope]
) throws -> DriveSetup {
    let accounts = GoogleAccounts(signIn: try #require(GoogleSignIn(clientID: clientID, http: fake)), keychain: keys)
    if let granted { try accounts.keep(address: driveOwner, refreshToken: "1//shared", granted: granted) }
    let key = try rootKey ?? .generate()
    let drive = GoogleDrive(accounts: accounts, store: store, rootKey: key, now: { Date(timeIntervalSince1970: 1_794_000_000) })
    return DriveSetup(drive: drive, accounts: accounts, store: store, rootKey: key)
}

@Suite struct DriveConnectTests {
    @Test func anAccountConnectedForCalendarIsOneTapAwayFromDrive() async throws {
        let fake = FakeDrive()
        let setup = try makeDrive(fake, granted: ["https://www.googleapis.com/auth/calendar.readonly"])
        #expect(await setup.drive.connections() == [DriveAccount(address: driveOwner, allowsDrive: false)])
        let authorization = try #require(await setup.drive.authorization(for: driveOwner))
        let asked = try #require(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in asked.first { $0.name == name }?.value }
        // Incremental consent on the same account: Google keeps Calendar and asks only for Drive.
        #expect(value("include_granted_scopes") == "true")
        #expect(value("login_hint") == driveOwner)
        #expect(value("scope")?.split(separator: " ").contains("https://www.googleapis.com/auth/drive") == true)
        // Without Drive allowed there's no token, so nothing in Drive is read.
        await #expect(throws: DriveProblem.notAllowed) { try await setup.drive.folders(in: .myDrive, account: driveOwner) }
        #expect(fake.listings.isEmpty)
    }

    @Test func choosesOnlyFoldersAndChecksWhatGoogleSends() async throws {
        let fake = FakeDrive()
        fake.children["root"] = [
            driveFolder("1AbC_school-notes", "School notes"),
            driveFile("1pdfReading", "Reading.pdf", mime: "application/pdf", size: 4_000),
            driveFolder("bad id'or'1=1", "Sneaky"),
            driveFolder("1Rec1pes", "Recipes\n\u{202E}gpj.exe"),
        ]
        let setup = try makeDrive(fake)
        let folders = try await setup.drive.folders(in: .myDrive, account: driveOwner)
        #expect(folders.map(\.id) == ["1AbC_school-notes", "1Rec1pes"])
        #expect(folders.allSatisfy { $0.isFolder })
        // Line breaks and direction tricks can't reach a row.
        #expect(folders[1].name == "Recipesgpj.exe")
        let first = try #require(fake.listings.first?.queryItems)
        let q = try #require(first.first { $0.name == "q" }?.value)
        #expect(q == "'root' in parents and trashed = false and mimeType = '\(DriveEntry.folderMime)'")
        #expect(fake.listings.count == 2)
    }

    @Test func aFolderIDThatIsntDrivesNeverReachesAQuery() async throws {
        let fake = FakeDrive()
        let setup = try makeDrive(fake)
        await #expect(throws: DriveProblem.unexpected) {
            try await setup.drive.folders(in: .folder(id: "x' or name contains 'a", name: "Sneaky"), account: driveOwner)
        }
        #expect(fake.listings.isEmpty)
    }

    @Test func sharedWithMeListsFoldersOthersShared() async throws {
        let fake = FakeDrive()
        fake.children["shared"] = [driveFolder("1team", "Book club")]
        let setup = try makeDrive(fake)
        #expect(try await setup.drive.folders(in: .sharedWithMe, account: driveOwner).map(\.name) == ["Book club"])
    }

    @Test func saysWhenTheDriveAPIIsntTurnedOn() async throws {
        let fake = FakeDrive()
        fake.status = 403
        fake.errorBody = ["error": ["errors": [["reason": "accessNotConfigured"]], "status": "PERMISSION_DENIED"]]
        let setup = try makeDrive(fake)
        await #expect(throws: DriveProblem.notSetUp) { try await setup.drive.folders(in: .myDrive, account: driveOwner) }
        fake.status = 401
        await #expect(throws: DriveProblem.expired) { try await setup.drive.folders(in: .myDrive, account: driveOwner) }
    }

    @Test func drivesScopeCountsAsItsOwnUse() {
        #expect(GoogleUse.uses(of: [DriveAPI.scope]) == [.drive])
    }
}

@Suite struct DriveLinkTests {
    @Test func linksAreSealedAndKeptAcrossLaunches() async throws {
        let fake = FakeDrive()
        let setup = try makeDrive(fake)
        let notes = DriveEntry(id: "1AbC_school-notes", name: "School notes", mime: DriveEntry.folderMime)
        try await setup.drive.link(notes, account: driveOwner)
        // Linking twice keeps one.
        try await setup.drive.link(notes, account: driveOwner)

        let reopened = GoogleDrive(accounts: setup.accounts, store: setup.store, rootKey: setup.rootKey)
        let links = try await reopened.links()
        #expect(links.map(\.name) == ["School notes"])
        #expect(links.first?.account == driveOwner)

        // Storage shows only an ID: no folder name, Drive ID or address.
        for name in try setup.store.names() {
            #expect(!name.contains("School") && !name.contains("1AbC") && !name.contains("gmail"))
            let blob = try #require(try setup.store.read(name))
            for secret in ["School notes", "1AbC_school-notes", driveOwner] {
                #expect(blob.range(of: Data(secret.utf8)) == nil)
            }
        }
    }

    @Test func onlyFoldersCanBeLinked() async throws {
        let setup = try makeDrive(FakeDrive())
        let file = DriveEntry(id: "1pdfReading", name: "Reading.pdf", mime: "application/pdf")
        await #expect(throws: DriveProblem.unexpected) { try await setup.drive.link(file, account: driveOwner) }
        #expect(try await setup.drive.links().isEmpty)
    }

    @Test func unlinkingForgetsOnlyThatFolder() async throws {
        let setup = try makeDrive(FakeDrive())
        try await setup.drive.link(DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime), account: driveOwner)
        let recipes = try await setup.drive.link(DriveEntry(id: "1recipes", name: "Recipes", mime: DriveEntry.folderMime), account: driveOwner)
        try await setup.drive.unlink(recipes)
        #expect(try await setup.drive.links().map(\.name) == ["School notes"])
    }

    @Test func aDisconnectedAccountsLinksDontShow() async throws {
        let setup = try makeDrive(FakeDrive())
        try await setup.drive.link(DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime), account: driveOwner)
        try setup.accounts.forget(driveOwner)
        #expect(try await setup.drive.links().isEmpty)
    }

    @Test func nothingIsWrittenAfterClosing() async throws {
        let setup = try makeDrive(FakeDrive())
        await setup.drive.close()
        await #expect(throws: ReaderError.closed) {
            try await setup.drive.link(DriveEntry(id: "1notes", name: "School notes", mime: DriveEntry.folderMime), account: driveOwner)
        }
        #expect(try setup.store.names().isEmpty)
    }
}

@Suite struct DriveTwoUserTests {
    @Test("User 2 never sees user 1's linked Drive folders")
    func user2SeesNoLinks() async throws {
        let fake = FakeDrive()
        let keys = MemoryKeys()
        let user1 = try makeDrive(fake, keys: keys)
        try await user1.drive.link(DriveEntry(id: "1diary", name: "Private diary", mime: DriveEntry.folderMime), account: driveOwner)

        // Same device storage, and even the same Google account still connected, but user 2's own key.
        let user2 = GoogleDrive(accounts: user1.accounts, store: user1.store, rootKey: try .generate())
        #expect(try await user2.links().isEmpty)
        // User 2 linking their own folder doesn't bring user 1's back.
        try await user2.link(DriveEntry(id: "1mine", name: "Mine", mime: DriveEntry.folderMime), account: driveOwner)
        #expect(try await user2.links().map(\.name) == ["Mine"])
    }
}
