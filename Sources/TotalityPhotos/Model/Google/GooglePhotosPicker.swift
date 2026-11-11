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
    /// The device hasn't room for a video and its sealed copy.
    case noRoom
    case unreachable
    case unexpected

    public var message: String {
        switch self {
        case .notAllowed: "Google Photos wasn't allowed on Google's page, so nothing came in. Try again and leave Google Photos ticked."
        case .expired: "Google needs you to sign in again. Choose the account again to carry on."
        case .turnedOff: "Google Photos isn't switched on for Totality yet, so nothing came in. This needs a change in Totality's Google settings."
        case .linksExpired: "Google's links to what you picked ran out. Pick again: anything already brought in is skipped."
        case .timedOut: "Google stopped waiting for you to pick. Start again when you're ready."
        case .noRoom: "This device is out of space, so the rest didn't come in. Free some up and pick again: anything already brought in is skipped."
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

/// The device's own download, remembering nothing between requests. The bytes go straight into
/// `file`, which is made first with complete protection, so no unprotected copy of a photo is ever left
/// in a system folder, and the download stops as soon as it passes the limit.
public struct EphemeralDownloader: GoogleDownloader {
    public init() {}

    public func download(_ request: URLRequest, to file: URL, limit: Int) async throws -> HTTPURLResponse {
        try? FileManager.default.removeItem(at: file)
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: attributes) else {
            throw PhotoError.cantOpen
        }
        let handle = try FileHandle(forWritingTo: file)
        let writer = DownloadWriter(handle: handle, limit: limit, host: request.url?.host?.lowercased())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: writer, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
            try? handle.close()
        }
        let task = session.dataTask(with: request)
        let response: HTTPURLResponse
        do {
            response = try await withTaskCancellationHandler {
                try await writer.finished(task)
            } onCancel: {
                task.cancel()
            }
        } catch {
            if writer.wentOver { throw PhotoError.tooBig }
            throw error
        }
        guard (200..<300).contains(response.statusCode) else { return response }
        guard writer.written > 0, writer.written <= limit else { throw PhotoError.tooBig }
        return response
    }
}

/// Writes one download into its file as it arrives. It follows a redirect only to Google's photo
/// hosts, and drops the Google token on any redirect to a different host, so the token goes only
/// where Google's own item link points.
private final class DownloadWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let host: String?
    private let lock = NSLock()
    private var over = false
    private var count = 0
    private var failure: Error?
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?

    init(handle: FileHandle, limit: Int, host: String?) {
        self.handle = handle
        self.limit = limit
        self.host = host
    }

    var wentOver: Bool { lock.withLock { over } }
    var written: Int { lock.withLock { count } }

    func finished(_ task: URLSessionDataTask) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { failure = GooglePhotosProblem.unexpected }
            completionHandler(.cancel)
            return
        }
        let tooBig = (200..<300).contains(http.statusCode) && http.expectedContentLength > Int64(limit)
        lock.withLock {
            self.response = http
            if tooBig { over = true }
        }
        // Only a success has bytes worth keeping.
        completionHandler(tooBig || !(200..<300).contains(http.statusCode) ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop: Bool = lock.withLock {
            guard !over, failure == nil else { return true }
            count += data.count
            if count > limit {
                over = true
                return true
            }
            do { try handle.write(contentsOf: data) } catch { failure = error; return true }
            return false
        }
        if stop { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, GooglePhotosPicker.isRedirectHost(url) else { return completionHandler(nil) }
        var next = request
        if url.host?.lowercased() != host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, response, failure) = lock.withLock {
            let held = self.continuation
            self.continuation = nil
            return (held, self.response, self.failure)
        }
        if let failure { return continuation?.resume(throwing: failure) ?? () }
        // A refusal was cancelled on purpose once its status arrived, so its status is the answer.
        if let response, !(200..<300).contains(response.statusCode) { return continuation?.resume(returning: response) ?? () }
        if let error { return continuation?.resume(throwing: error) ?? () }
        guard let response else { return continuation?.resume(throwing: GooglePhotosProblem.unexpected) ?? () }
        continuation?.resume(returning: response)
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
        var seen: Set<String> = []
        repeat {
            var components = URLComponents(url: Self.base.appendingPathComponent("mediaItems"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "sessionId", value: session), URLQueryItem(name: "pageSize", value: "100")]
                + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page: Page = try await decode(try await authorized(components.url!, method: "GET"))
            all += page.mediaItems ?? []
            token = page.nextPageToken
            // Google gives at most 2,000, a page of 100 at a time, so anything past that, or a page
            // token that comes round again, is refused rather than followed for ever.
            if let token, !seen.insert(token).inserted { throw GooglePhotosProblem.unexpected }
            guard all.count <= GooglePhotos.maxItems, seen.count <= GooglePhotos.maxItems / 100 + 5 else {
                throw GooglePhotosProblem.unexpected
            }
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

    /// The hosts Google's picked-item links point at (`lh3.googleusercontent.com` and its numbered
    /// siblings), over HTTPS. These are the only hosts the Google token is sent to.
    static func isPhotoHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), host.hasSuffix(".googleusercontent.com") else { return false }
        let name = host.dropLast(".googleusercontent.com".count)
        return name.hasPrefix("lh") && name.count > 2 && name.dropFirst(2).allSatisfy(\.isNumber)
    }

    /// Where a download may be sent on by Google: its photo and video hosts, over HTTPS. The token goes
    /// along only when the host stays the same.
    static func isRedirectHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return isPhotoHost(url) || host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".googlevideo.com")
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
