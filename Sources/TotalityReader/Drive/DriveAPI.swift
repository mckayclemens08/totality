import Foundation
import TotalityCore

/// What changed in one account's Drive since it was last asked.
struct DriveChanges: Equatable, Sendable {
    /// Every file and folder that changed, was moved, or was removed.
    var touched: Set<String> = []
    /// The folders the changed ones are in now.
    var parents: Set<String> = []
    /// Where to read from next time.
    var next: String
}

/// Why Google Drive couldn't be reached or used, in words the Reader can show.
public enum DriveProblem: Error, Equatable, Sendable {
    /// No connection to the internet.
    case offline
    /// Google couldn't be reached properly, or is busy.
    case unreachable
    /// Google took Totality's access back, or it ran out. Connecting again fixes it.
    case expired
    /// The Google account is connected, but hasn't allowed Drive. One tap on Google's page allows it.
    case notAllowed
    /// Totality's own Google project isn't set up for Drive, like the Drive API not being turned on.
    case notSetUp
    /// The folder or file is gone from Drive, or is no longer shared with this account.
    case notFound
    /// Google said something that doesn't fit.
    case unexpected
    /// Too big for Google to export, or for the Reader to open.
    case tooLarge

    /// True for a problem that usually clears on its own.
    public var isPassing: Bool {
        switch self {
        case .offline, .unreachable, .unexpected: true
        case .expired, .notAllowed, .notSetUp, .notFound, .tooLarge: false
        }
    }

    static func from(_ error: any Error) -> DriveProblem {
        if let problem = error as? DriveProblem { return problem }
        if let error = error as? GoogleSignInError {
            switch error {
            case .expired: return .expired
            case .notAllowed, .cancelled: return .notAllowed
            case .unreachable: return .unreachable
            case .refused, .unexpected: return .unexpected
            }
        }
        if let url = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(url.code) {
            return .offline
        }
        return .unreachable
    }

    public var message: String {
        switch self {
        case .offline: "You're offline. What's shown is from the last time Google Drive was reached."
        case .unreachable: "Google Drive couldn't be reached. Pull down to try again."
        case .expired: "Google took back Totality's access to this account. Connect it again to see its Drive folders."
        case .notAllowed: "This Google account hasn't allowed Totality to use its Drive yet."
        case .notSetUp: "Totality isn't set up to use Google Drive yet. That's on Totality's side, not your account's. Try again later."
        case .notFound: "This is no longer in Google Drive, or it's no longer shared with you."
        case .unexpected: "Google Drive sent something Totality didn't understand. Pull down to try again."
        case .tooLarge: "This file is too big to open here. Files up to 5 GB open, and text up to 64 MB. It's still in Google Drive."
        }
    }
}

/// One folder or file in Drive, as a listing gives it, once it's been checked.
public struct DriveEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let folderMime = "application/vnd.google-apps.folder"
    public static let googleDocMime = "application/vnd.google-apps.document"

    public let id: String
    public let name: String
    public let mime: String
    public let modifiedAt: Date?
    /// Bytes, for files that have them. Google's own files, like Docs, have none.
    public let size: Int?
    /// Drive's version number, which goes up with every change. A save checks it first.
    public let version: String?
    /// Whether this account may change the file in Drive.
    public let canEdit: Bool

    public init(id: String, name: String, mime: String, modifiedAt: Date? = nil, size: Int? = nil, version: String? = nil, canEdit: Bool = false) {
        self.id = id
        self.name = name
        self.mime = mime
        self.modifiedAt = modifiedAt
        self.size = size
        self.version = version
        self.canEdit = canEdit
    }

    public var isFolder: Bool { mime == Self.folderMime }
    public var isGoogleDoc: Bool { mime == Self.googleDocMime }
    /// Google's own formats, like Docs, Sheets and Slides, have no file to download, only exports.
    public var isGoogleFormat: Bool { mime.hasPrefix("application/vnd.google-apps.") }
    /// Plain text and Markdown, which the Reader can change and save back to Drive (step 4). Word
    /// files and Google Docs only open read-only, and Import makes a copy to edit.
    public var isEditableText: Bool {
        guard canEdit, !isGoogleFormat else { return false }
        return mime.hasPrefix("text/") || name.lowercased().hasSuffix(".md") || name.lowercased().hasSuffix(".txt")
    }
}

/// Where the folder chooser is looking.
public enum DrivePlace: Hashable, Sendable {
    /// The top of the person's own Drive.
    case myDrive
    /// Folders other people shared with this account.
    case sharedWithMe
    case folder(id: String, name: String)

    public var title: String {
        switch self {
        case .myDrive: "My Drive"
        case .sharedWithMe: "Shared with me"
        case .folder(_, let name): name
        }
    }
}

/// The Drive API v3, read through the shared Google sign-in's cookie-free connection. Every ID that goes
/// into a query is checked first, so nothing from a listing can change what's asked.
struct DriveAPI: Sendable {
    /// Full Drive access, the owner's named exception to minimal Google scopes (CLAUDE.md, rule 8).
    static let scope = "https://www.googleapis.com/auth/drive"
    static let base = URL(string: "https://www.googleapis.com/drive/v3")!
    /// So one huge folder can't fill the device or run forever.
    static let mostEntries = 5_000
    private static let pageSize = 1_000
    private static let entryFields = "id,name,mimeType,modifiedTime,size,version,trashed,capabilities/canEdit"

    let signIn: GoogleSignIn

    // MARK: Listing

    /// What's in a place. `foldersOnly` is for the chooser, which only links folders.
    func list(_ place: DrivePlace, foldersOnly: Bool, accessToken: String) async throws -> [DriveEntry] {
        var query: String
        switch place {
        case .myDrive: query = "'root' in parents"
        case .sharedWithMe: query = "sharedWithMe = true"
        case .folder(let id, _):
            guard Self.isID(id) else { throw DriveProblem.unexpected }
            query = "'\(id)' in parents"
        }
        query += " and trashed = false"
        if foldersOnly { query += " and mimeType = '\(DriveEntry.folderMime)'" }

        var found: [DriveEntry] = []
        var page: String?
        var pages = 0
        repeat {
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.entryFields))"),
                URLQueryItem(name: "pageSize", value: String(Self.pageSize)),
                URLQueryItem(name: "orderBy", value: "folder,name_natural"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            ]
            if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
            let listing: Listing = try await get(Self.url("files", items), accessToken: accessToken)
            found += listing.files.compactMap(\.entry)
            page = listing.nextPageToken
            pages += 1
        } while page != nil && found.count < Self.mostEntries && pages < 20
        return Array(found.prefix(Self.mostEntries))
    }

    // MARK: Searching

    /// The most a search asks Drive for, and the most words it sends.
    static let mostFound = 50
    static let mostTerms = 6

    /// Files whose text or name has every word, by Drive's own search. The words go to Google, and only
    /// to Google: it's the person's own Drive. Each word is quoted for Drive's query language, so nothing
    /// typed can change what's asked.
    func search(_ terms: [String], accessToken: String) async throws -> [(entry: DriveEntry, parents: [String])] {
        let words = terms.prefix(Self.mostTerms).map { String($0.prefix(100)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let query = words.map { "fullText contains \(Self.quoted($0))" }.joined(separator: " and ")
            + " and trashed = false and mimeType != '\(DriveEntry.folderMime)'"
        let items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(\(Self.entryFields),parents)"),
            URLQueryItem(name: "pageSize", value: String(Self.mostFound)),
            URLQueryItem(name: "corpora", value: "allDrives"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        let listing: Listing = try await get(Self.url("files", items), accessToken: accessToken)
        return listing.files.prefix(Self.mostFound).compactMap { file in file.entry.map { ($0, file.checkedParents) } }
    }

    /// The folders a folder is in, for following a found file up to a linked folder.
    func parents(of id: String, accessToken: String) async throws -> [String] {
        guard Self.isID(id) else { throw DriveProblem.unexpected }
        let items = [URLQueryItem(name: "fields", value: "id,parents"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        let file: File = try await get(Self.url("files/\(id)", items), accessToken: accessToken)
        return file.checkedParents
    }

    /// A word as a string in Drive's query language: in single quotes, with backslashes and quotes escaped.
    static func quoted(_ word: String) -> String {
        let cleaned = String(String.UnicodeScalarView(word.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return "'" + cleaned.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    // MARK: Changes

    /// Where an account's list of changes starts now. Only changes after this are read next time.
    func startPageToken(accessToken: String) async throws -> String {
        let answer: StartToken = try await get(Self.url("changes/startPageToken", [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]), accessToken: accessToken)
        guard Self.isID(answer.startPageToken) else { throw DriveProblem.unexpected }
        return answer.startPageToken
    }

    /// What changed in an account's Drive since `token`: the files and folders, the folders they're in
    /// now, and where to read from next time. Nil when there's too much to read this way, so the caller
    /// reads its folders whole instead.
    func changes(since token: String, accessToken: String) async throws -> DriveChanges? {
        guard Self.isID(token) else { throw DriveProblem.unexpected }
        var changes = DriveChanges(next: token)
        var page = token
        for _ in 0..<Self.mostChangePages {
            let answer: ChangeList = try await get(Self.url("changes", [
                URLQueryItem(name: "pageToken", value: page),
                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(parents,trashed))"),
                URLQueryItem(name: "pageSize", value: String(Self.pageSize)),
                URLQueryItem(name: "includeRemoved", value: "true"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            ]), accessToken: accessToken)
            for change in answer.changes ?? [] {
                guard let id = change.fileId, Self.isID(id) else { continue }
                changes.touched.insert(id)
                if change.removed != true, let parents = change.file?.parents {
                    changes.parents.formUnion(parents.filter(Self.isID))
                }
            }
            if let next = answer.newStartPageToken {
                guard Self.isID(next) else { throw DriveProblem.unexpected }
                changes.next = next
                return changes
            }
            guard let next = answer.nextPageToken, Self.isID(next) else { throw DriveProblem.unexpected }
            page = next
        }
        return nil
    }

    private static let mostChangePages = 10

    private struct StartToken: Decodable { let startPageToken: String }

    private struct ChangeList: Decodable {
        struct Change: Decodable {
            struct Parents: Decodable { let parents: [String]? }
            let fileId: String?
            let removed: Bool?
            let file: Parents?
        }
        let changes: [Change]?
        let nextPageToken: String?
        let newStartPageToken: String?
    }

    /// One file or folder's details, for checking a link is still there and what it's called now.
    func entry(_ id: String, accessToken: String) async throws -> DriveEntry {
        guard Self.isID(id) else { throw DriveProblem.unexpected }
        let file: File = try await get(Self.url("files/\(id)", [
            URLQueryItem(name: "fields", value: Self.entryFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]), accessToken: accessToken)
        guard let entry = file.entry else { throw DriveProblem.notFound }
        return entry
    }

    // MARK: Files

    /// A file's bytes. Google's own formats have none, so they come as an export in `export`'s format.
    func download(_ entry: DriveEntry, exportingAs export: String?, accessToken: String) async throws -> Data {
        guard Self.isID(entry.id) else { throw DriveProblem.unexpected }
        let url = if let export {
            Self.url("files/\(entry.id)/export", [URLQueryItem(name: "mimeType", value: export)])
        } else {
            Self.url("files/\(entry.id)", [
                URLQueryItem(name: "alt", value: "media"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    /// A file's bytes, handed to `receive` as they arrive, for a file too big to hold whole. Only a file
    /// stored in Drive comes this way: Google's own formats are exported, and an export is small.
    func download(_ entry: DriveEntry, into receive: @escaping @Sendable (Data) throws -> Void, accessToken: String) async throws {
        guard Self.isID(entry.id) else { throw DriveProblem.unexpected }
        var request = URLRequest(url: Self.url("files/\(entry.id)", [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let refusal: Data, response: HTTPURLResponse
        do {
            (refusal, response) = try await signIn.stream(request, into: receive)
        } catch let problem as DriveProblem {
            throw problem
        } catch let error as CryptoError {
            throw error
        } catch {
            throw DriveProblem.from(error)
        }
        try Self.check(response.statusCode, refusal)
    }

    static let uploadBase = URL(string: "https://www.googleapis.com/upload/drive/v3")!

    /// Saves new bytes over a file, which Drive keeps as a new revision.
    func update(_ id: String, data: Data, mime: String, accessToken: String) async throws -> DriveEntry {
        guard Self.isID(id), Self.isMime(mime) else { throw DriveProblem.unexpected }
        var components = URLComponents(url: Self.uploadBase.appendingPathComponent("files/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: Self.entryFields),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 120
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try Self.entry(from: try await send(request))
    }

    /// Makes a new file in a folder, for "Keep both".
    func create(named name: String, in parent: String, data: Data, mime: String, accessToken: String) async throws -> DriveEntry {
        guard Self.isID(parent), Self.isMime(mime) else { throw DriveProblem.unexpected }
        var components = URLComponents(url: Self.uploadBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: Self.entryFields),
        ]
        let boundary = "totality-" + UUID().uuidString
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent], "mimeType": mime])
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += metadata
        body += Data("\r\n--\(boundary)\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body += data
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try Self.entry(from: try await send(request))
    }

    private static func entry(from data: Data) throws -> DriveEntry {
        guard let file = try? JSONDecoder().decode(File.self, from: data), let entry = file.entry else { throw DriveProblem.unexpected }
        return entry
    }

    // MARK: Asking Google

    struct File: Decodable {
        struct Capabilities: Decodable { let canEdit: Bool? }
        let id: String
        let name: String?
        let mimeType: String?
        let modifiedTime: String?
        let size: String?
        let version: String?
        let trashed: Bool?
        let capabilities: Capabilities?
        /// Only asked for by search. Anything that isn't a Drive ID is dropped.
        let parents: [String]?

        var checkedParents: [String] { (parents ?? []).filter(DriveAPI.isID).prefix(10).map { $0 } }

        /// Nil for anything that doesn't check out, so it's left out rather than trusted.
        var entry: DriveEntry? {
            guard DriveAPI.isID(id), trashed != true, let mimeType, DriveAPI.isMime(mimeType) else { return nil }
            return DriveEntry(
                id: id, name: DriveAPI.cleanedName(name ?? ""), mime: mimeType,
                modifiedAt: modifiedTime.flatMap(DriveAPI.moment),
                size: size.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil },
                version: version.flatMap { $0.count <= 30 && $0.allSatisfy(\.isNumber) ? $0 : nil },
                canEdit: capabilities?.canEdit ?? false
            )
        }
    }

    private struct Listing: Decodable {
        let files: [File]
        let nextPageToken: String?
    }

    static func url(_ path: String, _ items: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // A "+" left as it is reads as a space at Google.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    func send(_ request: URLRequest) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await signIn.send(request)
        } catch {
            throw DriveProblem.from(error)
        }
        try Self.check(response.statusCode, data)
        return data
    }

    /// What an answer's status means.
    static func check(_ status: Int, _ body: Data) throws {
        switch status {
        case 200...204: return
        case 401: throw DriveProblem.expired
        case 403: throw Self.refusal(body)
        case 404, 410: throw DriveProblem.notFound
        case 429, 500...: throw DriveProblem.unreachable
        default: throw DriveProblem.unexpected
        }
    }

    private func get<Answer: Decodable>(_ url: URL, accessToken: String) async throws -> Answer {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw DriveProblem.unexpected }
        return answer
    }

    // MARK: Checking what Google says

    /// What a 403 means. Google says "too many" with a 403 as well as a 429, and a project without the
    /// Drive API turned on is Totality's setup, not the person's permission.
    static func refusal(_ data: Data) -> DriveProblem {
        let text = String(decoding: data.prefix(4_000), as: UTF8.self)
        if text.contains("ateLimitExceeded") || text.contains("RATE_LIMIT_EXCEEDED") { return .unreachable }
        if text.contains("accessNotConfigured") || text.contains("SERVICE_DISABLED") { return .notSetUp }
        if text.contains("exportSizeLimitExceeded") { return .tooLarge }
        if text.contains("insufficientPermissions") || text.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") { return .notAllowed }
        return .notFound
    }

    /// Drive's IDs are letters, digits, "-" and "_". Anything else never reaches a query or a path.
    static func isID(_ text: String) -> Bool {
        (1...200).contains(text.count) && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    static func isMime(_ text: String) -> Bool {
        (1...200).contains(text.count) && text.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    /// A name to show: no control characters or line breaks, and not too long.
    static func cleanedName(_ text: String) -> String {
        let shown = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }))
        let trimmed = String(shown.trimmingCharacters(in: .whitespaces).prefix(300))
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    static func moment(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
