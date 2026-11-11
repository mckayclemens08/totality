import Foundation
import TotalityCore

/// Google Photos through Google's Photos Picker API (issue 77, G1). Since March 2025 no app can read a
/// whole Google Photos library: the person picks photos, videos or albums in Google Photos, and Totality
/// gets only those. Every request goes from this device straight to Google, so Totality's server never
/// sees any of it.
public enum GooglePhotos {
    /// The only scope Photos asks for, added to the shared Google connection with one consent tap.
    public static let scope = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"
    /// Most items one picking session gives, by Google's rule.
    public static let maxItems = 2_000
}

/// Why something from Google didn't come in, in words for the person.
public enum GooglePhotosProblem: Error, Equatable, Sendable {
    /// The Google account didn't allow Google Photos on Google's page.
    case notAllowed
    /// Google took the account back, or the sign-in ran out (Testing mode lapses after 7 days).
    case expired
    /// The Photos Picker API isn't turned on for Totality's Google project.
    case turnedOff
    /// The picked items' links ran out, after about an hour.
    case linksExpired
    /// Picking took longer than Google waits.
    case timedOut
    case unreachable
    case unexpected

    public var message: String {
        switch self {
        case .notAllowed: "Google Photos wasn't allowed on Google's page, so nothing came in. Try again and leave Google Photos ticked."
        case .expired: "Google needs you to sign in again. Choose the account again to carry on."
        case .turnedOff: "Google Photos isn't switched on for Totality yet, so nothing came in. This needs a change in Totality's Google settings."
        case .linksExpired: "Google's links to what you picked ran out. Pick again: anything already brought in is skipped."
        case .timedOut: "Google stopped waiting for you to pick. Start again when you're ready."
        case .unreachable: "Google couldn't be reached. Try again when you're online."
        case .unexpected: "Google sent something Totality didn't expect. Try again in a moment."
        }
    }
}

/// One picking session, as Google describes it.
struct PickerSession: Decodable, Sendable, Equatable {
    struct Polling: Decodable, Sendable, Equatable {
        let pollInterval: String?
        let timeoutIn: String?
    }

    let id: String
    let pickerUri: URL?
    let pollingConfig: Polling?
    let mediaItemsSet: Bool?

    /// Google's duration strings look like "5s" or "1.5s".
    static func seconds(_ text: String?) -> Double? {
        guard let text, text.hasSuffix("s"), let value = Double(text.dropLast()), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// One item the person picked.
struct PickedItem: Decodable, Sendable, Equatable {
    struct MediaFile: Decodable, Sendable, Equatable {
        struct Metadata: Decodable, Sendable, Equatable {
            struct Video: Decodable, Sendable, Equatable { let processingStatus: String? }
            let videoMetadata: Video?
        }

        let baseUrl: URL
        let mimeType: String?
        let mediaFileMetadata: Metadata?
    }

    let id: String
    let type: String
    let mediaFile: MediaFile

    var isVideo: Bool { type == "VIDEO" }
    /// A video Google is still preparing can't be fetched yet.
    var isReady: Bool { !isVideo || mediaFile.mediaFileMetadata?.videoMetadata?.processingStatus == "READY" }
}

/// Fetches a picked item's bytes into a file, a piece at a time, so a video is never held in memory.
public protocol GoogleDownloader: Sendable {
    func download(_ request: URLRequest, to file: URL, limit: Int) async throws -> HTTPURLResponse
}

/// The device's own download, remembering nothing between requests.
public struct EphemeralDownloader: GoogleDownloader {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    public func download(_ request: URLRequest, to file: URL, limit: Int) async throws -> HTTPURLResponse {
        let watch = DownloadWatch(limit: limit)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: watch)
        } catch {
            if watch.wentOver { throw PhotoError.tooBig }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw GooglePhotosProblem.unexpected }
        guard (200..<300).contains(http.statusCode) else { return http }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= limit else { throw PhotoError.tooBig }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        #endif
        return http
    }
}

/// Watches one download: it stops as soon as it passes the size limit, rather than filling the
/// device first, and follows a redirect only to another of Google's photo hosts, so the Google token
/// never goes anywhere else.
private final class DownloadWatch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var over = false

    init(limit: Int) { self.limit = limit }

    var wentOver: Bool { lock.withLock { over } }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten > Int64(limit) || totalBytesExpectedToWrite > Int64(limit) else { return }
        lock.withLock { over = true }
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, GooglePhotosPicker.isPhotoHost(url) else { return nil }
        return request
    }
}

/// The Photos Picker API, called with a fresh token from the shared Google connection each time.
struct GooglePhotosPicker: Sendable {
    static let base = URL(string: "https://photospicker.googleapis.com/v1/")!

    let http: any GoogleHTTP
    let downloader: any GoogleDownloader
    let token: @Sendable () async throws -> String

    func createSession() async throws -> PickerSession {
        var request = try await authorized(Self.base.appendingPathComponent("sessions"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"pickingConfig":{"maxItemCount":"\#(GooglePhotos.maxItems)"}}"#.utf8)
        return try await decode(request)
    }

    func session(_ id: String) async throws -> PickerSession {
        try await decode(try await authorized(Self.base.appendingPathComponent("sessions").appendingPathComponent(id), method: "GET"))
    }

    /// Everything picked in the session, a page of 100 at a time.
    func items(_ session: String) async throws -> [PickedItem] {
        struct Page: Decodable {
            let mediaItems: [PickedItem]?
            let nextPageToken: String?
        }
        var all: [PickedItem] = []
        var token: String?
        repeat {
            var components = URLComponents(url: Self.base.appendingPathComponent("mediaItems"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "sessionId", value: session), URLQueryItem(name: "pageSize", value: "100")]
                + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page: Page = try await decode(try await authorized(components.url!, method: "GET"))
            all += page.mediaItems ?? []
            token = page.nextPageToken
            // Google gives at most 2,000, so anything past that is refused rather than followed for ever.
            guard all.count <= GooglePhotos.maxItems else { throw GooglePhotosProblem.unexpected }
        } while token != nil
        return all
    }

    /// The item at full resolution (`=d`, which Google gives without the location), or a video as
    /// Google's high-quality copy (`=dv`). Only Google's own photo hosts are ever asked.
    func download(_ item: PickedItem, to file: URL, limit: Int) async throws {
        guard let url = Self.downloadURL(item) else { throw GooglePhotosProblem.unexpected }
        let response = try await downloader.download(try await authorized(url, method: "GET"), to: file, limit: limit)
        try Self.check(response.statusCode, body: Data(), linkRequest: true)
    }

    static func downloadURL(_ item: PickedItem) -> URL? {
        let base = item.mediaFile.baseUrl
        guard isPhotoHost(base), base.query == nil, base.fragment == nil else { return nil }
        return URL(string: base.absoluteString + (item.isVideo ? "=dv" : "=d"))
    }

    /// Google's own photo hosts, over HTTPS.
    static func isPhotoHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com")
    }

    /// Tells Google the session is done with, which it asks for once the bytes are fetched.
    func deleteSession(_ id: String) async {
        guard let request = try? await authorized(Self.base.appendingPathComponent("sessions").appendingPathComponent(id), method: "DELETE") else { return }
        _ = try? await http.send(request)
    }

    private func authorized(_ url: URL, method: String) async throws -> URLRequest {
        let token: String
        do {
            token = try await self.token()
        } catch GoogleSignInError.notAllowed {
            throw GooglePhotosProblem.notAllowed
        } catch GoogleSignInError.expired {
            throw GooglePhotosProblem.expired
        } catch let problem as GooglePhotosProblem {
            throw problem
        } catch {
            throw GooglePhotosProblem.unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            throw GooglePhotosProblem.unreachable
        }
        try Self.check(response.statusCode, body: data, linkRequest: false)
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw GooglePhotosProblem.unexpected }
        return value
    }

    static func check(_ status: Int, body: Data, linkRequest: Bool) throws {
        switch status {
        case 200..<300: return
        case 401: throw GooglePhotosProblem.expired
        case 403 where String(decoding: body, as: UTF8.self).contains("SERVICE_DISABLED"): throw GooglePhotosProblem.turnedOff
        case 403: throw linkRequest ? GooglePhotosProblem.linksExpired : GooglePhotosProblem.notAllowed
        case 404, 410: throw GooglePhotosProblem.linksExpired
        case 500...: throw GooglePhotosProblem.unreachable
        default: throw GooglePhotosProblem.unexpected
        }
    }
}
