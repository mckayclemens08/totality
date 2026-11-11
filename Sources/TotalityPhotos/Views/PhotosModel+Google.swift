import Foundation
import TotalityCore

/// Opens Google's sign-in page and hands back where it returned to. The app gives the system's web
/// sign-in sheet.
public typealias PhotosWebSignIn = @MainActor (_ page: URL, _ callbackScheme: String) async throws -> URL

/// Where a Google Photos import stands, for the sheet.
public enum GoogleImportState: Equatable, Sendable {
    case idle
    case connecting
    /// Google Photos is open for the person to pick in.
    case picking
    case bringing(done: Int, total: Int)
    case finished(GoogleImportReport)
    case problem(String)
}

/// Add from Google Photos (issue 77). The Google account is the one shared connection in core, so a
/// Google account connected for Mail or Calendar needs one tap to allow Google Photos, not a second sign-in.
extension PhotosModel {
    public var canImportFromGoogle: Bool { googleAccounts != nil && account != nil }

    /// An import is signing in, picking, bringing, or still stopping. Only one runs at a time, and a
    /// stopped one has to finish stopping before another starts.
    public var isGoogleBusy: Bool { googleTask != nil || googleState == .connecting }

    /// Google accounts connected on this device, by address.
    public func googleConnections() -> [GoogleConnection] {
        (try? googleAccounts?.connections()) ?? []
    }

    /// Asks Google to allow Google Photos on `account`, or on a new account with nil, then lets the person
    /// pick in Google Photos, waits, and brings in what they picked.
    public func importFromGoogle(account: String?, albumName: String?, signIn: PhotosWebSignIn, open: @escaping @MainActor (URL) -> Void) async {
        guard let googleAccounts, let library = photoLibrary, !isGoogleBusy else { return }
        let address: String
        googleState = .connecting
        do {
            if let account, let connection = try googleAccounts.connection(account), connection.allows([GooglePhotos.scope]) {
                address = connection.address
            } else {
                let authorization = googleAccounts.authorization(for: [GooglePhotos.scope], account: account)
                let callback = try await signIn(authorization.url, authorization.callbackScheme)
                let connection = try await googleAccounts.finish(authorization, callback: callback)
                guard connection.allows([GooglePhotos.scope]) else { throw GooglePhotosProblem.notAllowed }
                address = connection.address
            }
        } catch let problem as GooglePhotosProblem {
            googleState = .problem(problem.message)
            return
        } catch GoogleSignInError.cancelled {
            googleState = .idle
            return
        } catch is CancellationError {
            googleState = .idle
            return
        } catch {
            // The web sign-in sheet closed without an answer counts as stopping, not a problem.
            if (error as NSError).domain == "com.apple.AuthenticationServices.WebAuthenticationSession" {
                googleState = .idle
            } else {
                googleState = .problem(GooglePhotosProblem.unreachable.message)
            }
            return
        }
        let importer = GooglePhotosImport(library: library, picker: GooglePhotosPicker(
            http: EphemeralHTTP(), downloader: EphemeralDownloader(),
            token: { try await googleAccounts.accessToken(address, for: [GooglePhotos.scope]) }
        ))
        // Only this task clears its own handle, once it has really ended.
        googleTask = Task { [weak self] in
            await self?.runImport(importer, albumName: albumName, open: open)
            self?.googleTask = nil
        }
    }

    private func runImport(_ importer: GooglePhotosImport, albumName: String?, open: @MainActor (URL) -> Void) async {
        do {
            let session = try await importer.start()
            guard let page = session.pickerUri else { throw GooglePhotosProblem.unexpected }
            try Task.checkCancellation()
            googleState = .picking
            open(page)
            try await importer.waitForPicks(session)
            try Task.checkCancellation()
            googleState = .bringing(done: 0, total: 0)
            let background = BackgroundTime.begin()
            defer { background.end() }
            let report = await importer.bring(session.id, albumName: albumName) { [weak self] done, total in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.googleState = .bringing(done: done, total: total)
                }
            }
            if !Task.isCancelled { googleState = report.problem.map { .problem($0.message) } ?? .finished(report) }
            if report.full { isFull = true }
            if report.brought > 0 {
                await refreshAfterSync()
                albums = (try? await importer.library.albums().albums) ?? albums
            }
        } catch let problem as GooglePhotosProblem {
            googleState = .problem(problem.message)
        } catch {
            googleState = Task.isCancelled ? .idle : .problem(GooglePhotosProblem.unexpected.message)
        }
    }

    /// Stops waiting or bringing. What came in stays, and is skipped if picked again.
    public func stopGoogleImport() {
        googleTask?.cancel()
        googleState = .idle
    }

    public func clearGoogleImport() {
        guard googleTask == nil else { return }
        googleState = .idle
    }

    /// The finished import, in words.
    nonisolated static func googleSummary(_ report: GoogleImportReport) -> String {
        func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count.formatted()) items" }
        var parts = [report.brought == 0 ? "Nothing new came in." : "\(items(report.brought)) came in from Google Photos."]
        if report.already > 0 { parts.append("\(items(report.already)) had come in before, so they were skipped.") }
        if report.notReady > 0 { parts.append("\(items(report.notReady)) are videos Google is still preparing. Pick them again later.") }
        if report.cantTake > 0 { parts.append("\(items(report.cantTake)) couldn't be brought in, because they're too big, too long, or not something Photos reads.") }
        if report.failed > 0 { parts.append("\(items(report.failed)) didn't come in. Pick them again to try once more.") }
        if report.full { parts.append("Your space is full, so the rest didn't come in.") }
        return parts.joined(separator: " ")
    }
}
