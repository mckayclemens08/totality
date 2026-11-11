import Foundation

/// What iPhone sync keeps on the device, sealed: how it's set, and what it has already brought in. Issue 77.
public struct SyncRecord: Codable, Sendable, Equatable {
    /// The account it belongs to. A record naming another account is never used.
    public var account = ""
    public var isOn = false
    /// Items from this day on sync. Set when sync is first turned on.
    public var start: Date?
    /// Earlier months the person chose to bring in too, as "2026-10".
    public var months: Set<String> = []
    /// Videos are off at first, because they're most of a library's size (P3).
    public var videos = false
    /// Off at first: sync waits for Wi-Fi (P4).
    public var mobileData = false
    /// The iPhone's IDs for everything brought in. Kept after a photo is deleted in Totality, so sync never
    /// brings it back (P5).
    public var synced: Set<String> = []
    /// Items Photos can't take (too long, too big, or not a photo it can read), so they aren't read again
    /// on every run.
    public var skipped: Set<String> = []

    public init() {}
}

extension JSONEncoder {
    static var syncRecord: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

extension JSONDecoder {
    static var syncRecord: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// One item in the iPhone's library, as sync sees it before reading anything of it.
public struct SyncCandidate: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case photo, live, video }
    public let id: String
    public let created: Date?
    public let kind: Kind
    public let duration: Double?

    public init(id: String, created: Date?, kind: Kind, duration: Double? = nil) {
        self.id = id
        self.created = created
        self.kind = kind
        self.duration = duration
    }
}

/// An item read out of the iPhone's library. Files are plain copies sync removes once they're sealed.
public enum SyncExport: Sendable {
    case photo(Data)
    case live(still: Data, motion: URL)
    case video(URL)

    var files: [URL] {
        switch self {
        case .photo: []
        case .live(_, let motion): [motion]
        case .video(let file): [file]
        }
    }
}

public enum SyncSourceError: Error, Equatable, Sendable {
    /// The original is only in iCloud, and sync isn't letting it download now.
    case inICloud
    case unreadable
}

/// The iPhone's library. On iPhone it's PhotoKit; tests give their own.
public protocol SyncSource: Sendable {
    /// Every item the app may see, newest first. With Limited access that's only what the person chose.
    func candidates() async -> [SyncCandidate]
    /// Reads one item. `download` lets an original that's only in iCloud come down first.
    func export(_ candidate: SyncCandidate, download: Bool) async throws -> SyncExport
}

/// What a sync run got done, and what's stopping the rest.
public struct SyncReport: Sendable, Equatable {
    public var brought = 0
    /// Still to bring in after this run.
    public var remaining = 0
    /// Only in iCloud, waiting for Wi-Fi.
    public var waitingForWiFi = 0
    /// Items Photos can't take: videos over 10 minutes, files over 4 GB, or what isn't a photo it can read.
    public var cantTake = 0
    public var failed = 0
    public var full = false
    public var offline = false
    public var stopped = false

    public init() {}
}

/// Brings the iPhone's photos into the library, one at a time: each is read, sealed on the device, and
/// uploaded before the next, so a big library never needs much free space at once. Only what the record
/// says to bring, and never anything already brought.
public actor LibrarySync {
    let library: PhotoLibrary
    private let source: any SyncSource
    private let calendar: Calendar

    public init(library: PhotoLibrary, source: any SyncSource, calendar: Calendar = .current) {
        self.library = library
        self.source = source
        self.calendar = calendar
    }

    public nonisolated var account: String { library.account }

    /// The months the library has, newest first, with how many items in each, for choosing earlier ones.
    public func months() async -> [(id: String, count: Int)] {
        var counts: [String: Int] = [:]
        for candidate in await source.candidates() {
            guard let created = candidate.created else { continue }
            counts[Self.month(of: created, calendar), default: 0] += 1
        }
        return counts.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    nonisolated static func month(of date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// What the record asks for that isn't brought in yet, newest first.
    public func pending(_ record: SyncRecord) async -> [SyncCandidate] {
        guard record.isOn else { return [] }
        return await source.candidates().filter { wants($0, record) }
    }

    private func wants(_ candidate: SyncCandidate, _ record: SyncRecord) -> Bool {
        guard record.isOn, !record.synced.contains(candidate.id), !record.skipped.contains(candidate.id) else { return false }
        if candidate.kind == .video, !record.videos { return false }
        guard let created = candidate.created else { return false }
        if let start = record.start, created >= start { return true }
        return record.months.contains(Self.month(of: created, calendar))
    }

    /// A run with the network as it is now, for tests.
    public func run(onWiFi: Bool, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async -> SyncReport {
        await run(network: { onWiFi }, progress: progress)
    }

    /// One run. `network` says whether the device is on Wi-Fi, asked before each item, since the phone can
    /// leave it partway. Wi-Fi lets iCloud-only originals come down (P7), and lets sync go at all unless the
    /// record allows mobile data. The record is read again before each item too, so a setting changed
    /// partway counts from the next one. `progress` hears how many have come in so far.
    public func run(network: @Sendable () async -> Bool, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async -> SyncReport {
        // One run per library, whichever screen asked.
        guard await library.beginSync() else { return SyncReport() }
        let report = await runOnce(network: network, progress: progress)
        await library.endSync()
        return report
    }

    private func runOnce(network: @Sendable () async -> Bool, progress: @Sendable (Int, Int) async -> Void) async -> SyncReport {
        var report = SyncReport()
        guard let first = try? await library.syncRecord(), first.isOn else { return report }
        let todo = await pending(first)
        report.remaining = todo.count
        guard !todo.isEmpty else { return report }
        for candidate in todo {
            if Task.isCancelled {
                report.stopped = true
                break
            }
            guard let record = try? await library.syncRecord(), record.isOn else {
                report.stopped = true
                break
            }
            guard wants(candidate, record) else { continue }
            let onWiFi = await network()
            guard onWiFi || record.mobileData else {
                report.offline = true
                break
            }
            if candidate.kind == .video, (candidate.duration ?? 0) > VideoImport.maxDuration + 0.5 {
                report.cantTake += 1
                try? await library.updateSyncRecord { $0.skipped.insert(candidate.id) }
                continue
            }
            let export: SyncExport
            do {
                export = try await source.export(candidate, download: onWiFi)
            } catch SyncSourceError.inICloud {
                report.waitingForWiFi += 1
                continue
            } catch {
                report.failed += 1
                continue
            }
            defer { for file in export.files { try? FileManager.default.removeItem(at: file) } }
            do {
                switch export {
                case .photo(let data): _ = try await library.add(data)
                case .live(let still, let motion): _ = try await library.addLive(still: still, motion: motion)
                case .video(let file): _ = try await library.addVideo(file)
                }
            } catch PhotoError.closed {
                report.stopped = true
                break
            } catch let error as PhotoError where [.tooLong, .tooBig, .notAPhoto].contains(error) {
                report.cantTake += 1
                try? await library.updateSyncRecord { $0.skipped.insert(candidate.id) }
                continue
            } catch {
                report.failed += 1
                continue
            }
            // Sealed on the device now, so it's never read again even if the upload waits.
            do { try await library.updateSyncRecord { $0.synced.insert(candidate.id) } } catch {
                report.stopped = true
                break
            }
            report.brought += 1
            await progress(report.brought, todo.count)
            if Task.isCancelled {
                report.stopped = true
                break
            }
            let upload = await library.upload()
            if upload.full {
                report.full = true
                break
            }
            if upload.offline {
                report.offline = true
                break
            }
        }
        if let latest = try? await library.syncRecord() { report.remaining = await pending(latest).count }
        return report
    }
}
