import Foundation
import TotalityCore

/// What Google Photos import keeps on the device, sealed: which Google items have come in, so picking
/// one again never brings it twice (G4), and the session being imported, so an import that stops carries on.
public struct GoogleImportRecord: Codable, Sendable, Equatable {
    public var account = ""
    public var imported: Set<String> = []
    public var session: String?
    /// The album an import that stopped was putting things in.
    public var album: UUID?

    public init() {}
}

/// What one import got done.
public struct GoogleImportReport: Sendable, Equatable {
    public var brought = 0
    /// Picked before, and skipped.
    public var already = 0
    /// Videos Google is still preparing. Picking them again later brings them.
    public var notReady = 0
    /// Over 100 MB for a photo or 4 GB for a video, or a video over 10 minutes, or not something Photos reads.
    public var cantTake = 0
    public var failed = 0
    public var full = false
    public var problem: GooglePhotosProblem?

    public init() {}
}

/// Brings what the person picked in Google Photos into the library, one item at a time: fetched from
/// Google straight to this device, sealed here, and uploaded before the next.
public actor GooglePhotosImport {
    let library: PhotoLibrary
    private let picker: GooglePhotosPicker
    private let pause: @Sendable (Double) async throws -> Void

    init(library: PhotoLibrary, picker: GooglePhotosPicker, pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.library = library
        self.picker = picker
        self.pause = pause
    }

    /// Starts a picking session. Its address opens Google Photos for the person to pick in.
    func start() async throws -> PickerSession {
        let session = try await picker.createSession()
        guard session.pickerUri.map({ Self.isGoogle($0) }) == true else { throw GooglePhotosProblem.unexpected }
        // A new pick starts fresh, so an album from one that stopped isn't reused for a different name.
        try await library.updateGoogleRecord { record in
            record.session = session.id
            record.album = nil
        }
        return session
    }

    /// Room for `size` more bytes and 500 MB to spare, where the files are. Unknown counts as room.
    static func hasRoom(for size: Int, beside file: URL) -> Bool {
        let folder = file.deletingLastPathComponent()
        guard let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free > 0 else { return true }
        return free >= Int64(size) + 500_000_000
    }

    static func isGoogle(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "photos.google.com" || host.hasSuffix(".google.com")
    }

    /// Waits for the person to finish picking, asking Google as often as it says to.
    func waitForPicks(_ session: PickerSession) async throws {
        var current = session
        var waited = 0.0
        // Google says how long it waits. Totality waits no more than an hour, whatever it says.
        let limit = min(PickerSession.seconds(session.pollingConfig?.timeoutIn) ?? 1_800, 3_600)
        while current.mediaItemsSet != true {
            let interval = min(max(PickerSession.seconds(current.pollingConfig?.pollInterval) ?? 5, 1), 60)
            guard waited + interval <= limit else { throw GooglePhotosProblem.timedOut }
            try await pause(interval)
            waited += interval
            current = try await picker.session(session.id)
        }
    }

    /// Brings in what was picked. With `albumName`, everything goes into one new album of that name.
    func bring(_ session: String, albumName: String?, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async -> GoogleImportReport {
        var report = GoogleImportReport()
        let items: [PickedItem]
        do {
            items = try await picker.items(session)
        } catch let problem as GooglePhotosProblem {
            report.problem = problem
            return report
        } catch {
            report.problem = .unexpected
            return report
        }
        guard let record = try? await library.googleRecord() else {
            report.problem = .unexpected
            return report
        }
        var album = record.album
        let todo = items.filter { !record.imported.contains($0.id) }
        report.already = items.count - todo.count
        for item in todo {
            if Task.isCancelled { break }
            // Read again each time, so an item another import on this device brought in meanwhile is skipped.
            if (try? await library.googleRecord().imported.contains(item.id)) == true {
                report.already += 1
                continue
            }
            guard item.isReady else {
                report.notReady += 1
                continue
            }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("totality-\(UUID().uuidString)")
                .appendingPathExtension(item.isVideo ? "mp4" : "img")
            defer { try? FileManager.default.removeItem(at: file) }
            let added: PhotoItem
            do {
                try await picker.download(item, to: file, limit: item.isVideo ? VideoImport.maxBytes : PhotoImport.maxBytes)
                if Task.isCancelled { break }
                if item.isVideo {
                    // Sealing writes a second copy as big as the video, so it needs that room and some over.
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard Self.hasRoom(for: size, beside: file) else { throw GooglePhotosProblem.noRoom }
                    added = try await library.addVideo(file)
                } else {
                    let data = try Data(contentsOf: file)
                    try? FileManager.default.removeItem(at: file)
                    added = try await library.add(data)
                }
            } catch let problem as GooglePhotosProblem {
                report.problem = problem
                break
            } catch PhotoError.closed {
                break
            } catch let error as PhotoError where [.tooBig, .tooLong, .notAPhoto].contains(error) {
                report.cantTake += 1
                try? await library.updateGoogleRecord { $0.imported.insert(item.id) }
                continue
            } catch {
                report.failed += 1
                continue
            }
            do { try await library.updateGoogleRecord { $0.imported.insert(item.id) } } catch { break }
            if let name = albumName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if album == nil, let made = try? await library.makeAlbum(named: name) {
                    album = made.id
                    let id = made.id
                    try? await library.updateGoogleRecord { $0.album = id }
                }
                if let album {
                    _ = try? await library.change(added) { details in
                        details.albums = Array(Set(details.albums ?? []).union([album]))
                    }
                }
            }
            report.brought += 1
            await progress(report.brought, todo.count)
            let upload = await library.upload()
            if upload.full {
                report.full = true
                break
            }
        }
        let finished = report.problem == nil && !report.full && !Task.isCancelled
        if finished {
            await picker.deleteSession(session)
            try? await library.updateGoogleRecord { record in
                record.session = nil
                record.album = nil
            }
        }
        return report
    }
}
