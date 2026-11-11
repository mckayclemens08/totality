import CoreGraphics
import Foundation
import Observation
import TotalityCore

/// The Photos screens' state. Thumbnails are opened on the device and kept in memory only.
@MainActor
@Observable
public final class PhotosModel {
    public enum Phase: Equatable {
        case loading
        case ready
        /// Photos can't open, and why, in words for the person.
        case unavailable(title: String, detail: String)
    }

    /// Which photos a grid or the viewer shows.
    public enum Scope: Hashable, Sendable {
        case library, favourites, videos, recentlyDeleted
        case album(UUID)
    }

    public struct Month: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let items: [PhotoItem]
    }

    public private(set) var phase: Phase = .loading
    /// Every photo, Recently Deleted included. `items(in:)` picks the ones a screen shows.
    public private(set) var items: [PhotoItem] = []
    public internal(set) var albums: [PhotoAlbum] = []
    public private(set) var usage: SealedStoreUsage?
    public private(set) var waitingCount = 0
    public internal(set) var isFull = false
    public private(set) var isOffline = false
    public private(set) var isAdding = false
    public private(set) var unreadable = 0
    public var notice: String?
    /// What would let Photos open, when it can't. Nil when there's nothing the person can do here.
    public private(set) var fix: Fix?
    /// What carries a share to another person, set by the app where that runs. Nil hides Share.
    public var sender: (any PersonSender)?
    /// How far a share has got, while one is going.
    public private(set) var sharing: (done: Int, total: Int)?
    /// How many items the last share got through.
    public private(set) var lastShareSent = 0
    /// A photo the home tile asked for. Photos opens it in the viewer and clears this.
    public var requestedItem: UUID?

    public enum Fix: Equatable, Sendable {
        /// Signing in, or setting up the recovery key, both of which live in the account.
        case openAccount
        case tryAgain
    }
    /// Photos per row in the library. Pinching changes it.
    public var columns = PhotosModel.defaultColumns

    #if os(macOS)
    public static let defaultColumns = 6
    public static let columnRange = 3...10
    #else
    public static let defaultColumns = 3
    public static let columnRange = 2...6
    #endif

    private let library: PhotoLibrary?
    /// iPhone sync for this library, where the device has a photo library to read (issue 77).
    let librarySync: LibrarySync?
    /// How sync is set and what it has brought, once read. Nil before then, or where there's no sync.
    public internal(set) var syncRecord: SyncRecord?
    /// The last run's outcome, for the line under the library.
    public internal(set) var syncReport: SyncReport?
    /// How far the run going now has got.
    public internal(set) var syncProgress: (done: Int, total: Int)?
    var syncTask: Task<Void, Never>?
    /// The device's Google accounts, shared with Mail and Calendar, set by the app where there's a client ID.
    public var googleAccounts: GoogleAccounts?
    /// Where a Google Photos import stands.
    public internal(set) var googleState: GoogleImportState = .idle
    var googleTask: Task<Void, Never>?
    var photoLibrary: PhotoLibrary? { library }
    /// Leftover plain files are cleared once each launch, before anything new is picked.
    private static var sweptThisLaunch = false
    private let unavailable: (title: String, detail: String)
    private var thumbnails: [UUID: CGImage] = [:]
    private var thumbnailOrder: [UUID] = []
    private static let thumbnailsKept = 400

    /// With no library, Photos explains why, in `unavailable`'s words.
    public init(
        library: PhotoLibrary?, unavailable: (title: String, detail: String) = PhotosModel.signedOut, fix: Fix? = .openAccount,
        syncSource: (any SyncSource)? = PhotosModel.deviceLibrary
    ) {
        self.library = library
        self.unavailable = unavailable
        librarySync = library.flatMap { library in syncSource.map { LibrarySync(library: library, source: $0) } }
        if library == nil {
            phase = .unavailable(title: unavailable.title, detail: unavailable.detail)
            self.fix = fix
        }
        // Background time iOS gives goes to this library's sync, or to nothing once it's gone.
        if librarySync == nil {
            SyncSchedule.run = nil
            SyncSchedule.stop = nil
        } else {
            SyncSchedule.run = { @MainActor [weak self] in await self?.runSync() }
            SyncSchedule.stop = { @MainActor [weak self] in self?.stopSync() }
        }
        refresher.add("library") { [weak self] in
            guard let self else { return .done }
            await self.refreshAfterSync()
            return self.isOffline ? .offline : .done
        }
    }

    /// The device's own photo library, on iPhone only (P9).
    public static var deviceLibrary: (any SyncSource)? {
        #if os(iOS)
        PhotoKitSource()
        #else
        nil
        #endif
    }

    public static let signedOut = (
        title: "Sign in to use Photos",
        detail: "Photos are kept sealed in your account, so Photos needs you signed in on a device that has joined your recovery key."
    )

    /// Signed in, but this device hasn't joined the recovery key, so nothing sealed here could be got back.
    public static let needsRecoveryKey = (
        title: "Set up your recovery key first",
        detail: "Photos are sealed on this device before they upload, and your recovery key is what gets them back on a new one. Set it up in your account, then come back."
    )

    /// This device's key belongs to someone else, so their photos stay theirs.
    public static let otherAccountsKey = (
        title: "This device is set up for another account",
        detail: "Photos open only for the account that holds this device's key. Sign in as that account to see its photos."
    )

    public var account: String? { library?.account }

    /// Brings the library list up to date, quietly. It never starts backing up the camera roll.
    public let refresher = Refresher()

    // MARK: Loading

    public func load() async {
        guard let library else { return }
        if !Self.sweptThisLaunch, !isAdding {
            Self.sweptThisLaunch = true
            Self.removeLeftoverPlainFiles()
        }
        do {
            let listing = try await library.list()
            items = listing.items
            unreadable = listing.unreadable
            isOffline = !listing.isCurrent
            waitingCount = listing.items.filter(\.isWaiting).count
            phase = .ready
            fix = nil
            albums = try await library.albums().albums
        } catch PhotoError.closed {
            // The account changed under this library, so nothing of it stays on screen.
            items = []
            albums = []
            thumbnails = [:]
            phase = .unavailable(title: "Photos are closed", detail: "These photos belong to another account. Sign in as that account to see them.")
            fix = .openAccount
            return
        } catch {
            if items.isEmpty {
                phase = .unavailable(title: "Photos couldn't open", detail: "Something went wrong reading this device's copy. Try again in a moment.")
                fix = .tryAgain
            }
            return
        }
        usage = try? await library.usage()
        await upload()
        await loadSync()
        startSync()
    }

    /// After "Photos couldn't open", shows the spinner again and has another go.
    public func tryAgain() async {
        guard library != nil, fix == .tryAgain else { return }
        phase = .loading
        fix = nil
        await load()
    }

    /// Sends what's waiting, and says what's stopping it.
    public func upload() async {
        guard let library else { return }
        // Asks iOS for time to finish if Totality goes into the background. It's up to iOS how long.
        let background = BackgroundTime.begin()
        let report = await library.upload()
        background.end()
        isFull = report.full
        if report.offline { isOffline = true }
        if report.sent > 0 {
            if let listing = try? await library.list() {
                items = listing.items
                isOffline = !listing.isCurrent
            }
            usage = try? await library.usage()
        }
        waitingCount = items.filter(\.isWaiting).count
    }

    /// The library as it is after sync brought things in.
    func refreshAfterSync() async {
        guard let library else { return }
        if let listing = try? await library.list() {
            items = listing.items
            isOffline = !listing.isCurrent
        }
        waitingCount = items.filter(\.isWaiting).count
        usage = try? await library.usage()
    }

    // MARK: Adding

    /// Adds the photos the person picked. `files` loads each one, so the picker's items never reach here.
    /// One thing the person picked, and how to load it. Files a loader makes are its own copies, and are
    /// removed here once they're sealed.
    public enum Pick: Sendable {
        case photo(@Sendable () async throws -> Data?)
        case video(@Sendable () async throws -> URL?)
        /// A Live Photo, and its still alone in case the movement can't be had.
        case live(@Sendable () async throws -> (still: Data, motion: URL)?, still: @Sendable () async throws -> Data?)
    }

    /// Adds the photos the person picked, compatible with step 2's callers.
    public func add(_ files: [@Sendable () async throws -> Data?]) async {
        await add(picks: files.map { .photo($0) })
    }

    /// Adds what the person picked. The picker's items never reach here, only their loaders.
    public func add(picks: [Pick]) async {
        guard let library, !picks.isEmpty else { return }
        isAdding = true
        defer { isAdding = false }
        var added: [PhotoItem] = []
        var problems = AddProblems()
        for pick in picks {
            var made: [URL] = []
            do {
                switch pick {
                case .photo(let load):
                    guard let data = try await load() else { throw PhotoError.notAPhoto }
                    added.append(try await library.add(data))
                case .video(let load):
                    guard let file = try await load() else { throw PhotoError.notAPhoto }
                    made.append(file)
                    added.append(try await library.addVideo(file))
                case .live(let load, let still):
                    if let live = try? await load() {
                        made.append(live.motion)
                        added.append(try await library.addLive(still: live.still, motion: live.motion))
                    } else {
                        guard let data = try await still() else { throw PhotoError.notAPhoto }
                        added.append(try await library.add(data))
                    }
                }
            } catch PhotoError.tooBig {
                problems.tooBig += 1
            } catch PhotoError.tooLong {
                problems.tooLong += 1
            } catch {
                problems.skipped += 1
            }
            for file in made { try? FileManager.default.removeItem(at: file) }
        }
        if !added.isEmpty {
            items = (added + items).sorted { $0.date != $1.date ? $0.date > $1.date : $0.id.uuidString < $1.id.uuidString }
            waitingCount = items.filter(\.isWaiting).count
            if phase != .ready { phase = .ready }
        }
        notice = Self.addNotice(problems)
        await upload()
    }

    struct AddProblems: Equatable {
        var skipped = 0
        var tooBig = 0
        var tooLong = 0
    }

    nonisolated static func addNotice(skipped: Int, tooBig: Int) -> String? {
        addNotice(AddProblems(skipped: skipped, tooBig: tooBig))
    }

    nonisolated static func addNotice(_ problems: AddProblems) -> String? {
        var parts: [String] = []
        if problems.tooBig > 0 {
            parts.append(problems.tooBig == 1 ? "One item is too big to add." : "\(problems.tooBig) items are too big to add.")
        }
        if problems.tooLong > 0 {
            parts.append(problems.tooLong == 1 ? "One video is over 10 minutes, so it wasn't added."
                : "\(problems.tooLong) videos are over 10 minutes, so they weren't added.")
        }
        if problems.skipped > 0 {
            parts.append(problems.skipped == 1 ? "One item couldn't be read as a photo or video." : "\(problems.skipped) items couldn't be read as photos or videos.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Changing

    public func toggleFavourite(_ item: PhotoItem) async {
        let on = !(current(item)?.details.favourite ?? item.details.favourite)
        await change(item) { $0.isFavourite = on ? true : nil }
    }

    public func setCaption(_ item: PhotoItem, to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = trimmed.isEmpty ? nil : String(trimmed.prefix(PhotoDetails.captionLimit))
        guard caption != current(item)?.details.caption else { return }
        await change(item) { $0.caption = caption }
    }

    public func set(_ item: PhotoItem, in album: PhotoAlbum, _ included: Bool) async {
        await change(item) { details in
            var ids = details.albumIDs.filter { $0 != album.id }
            if included { ids.append(album.id) }
            details.albums = ids.isEmpty ? nil : ids
        }
    }

    /// Recently Deleted keeps it for 30 days.
    public func moveToRecentlyDeleted(_ item: PhotoItem) async {
        let now = Date()
        await change(item) { $0.trashed = now }
    }

    public func restore(_ item: PhotoItem) async {
        await change(item) { $0.trashed = nil }
    }

    public func deleteForGood(_ item: PhotoItem) async {
        guard let library else { return }
        do {
            try await library.deleteForGood(item)
            items.removeAll { $0.id == item.id }
            thumbnails[item.id] = nil
            waitingCount = items.filter(\.isWaiting).count
            usage = try? await library.usage()
        } catch {
            notice = Self.problem(error, doing: "delete that photo")
        }
    }

    public func emptyRecentlyDeleted() async {
        for item in items(in: .recentlyDeleted) { await deleteForGood(item) }
    }

    /// The latest copy of a photo, which may have changed since a screen was given it.
    public func current(_ item: PhotoItem) -> PhotoItem? {
        items.first { $0.id == item.id }
    }

    private func change(_ item: PhotoItem, _ edit: @escaping @Sendable (inout PhotoDetails) -> Void) async {
        guard let library else { return }
        do {
            let changed = try await library.change(current(item) ?? item, edit)
            if let index = items.firstIndex(where: { $0.id == changed.id }) { items[index] = changed }
        } catch {
            notice = Self.problem(error, doing: "save that change")
        }
    }

    // MARK: Albums

    public func makeAlbum(named name: String) async -> PhotoAlbum? {
        guard let library else { return nil }
        do {
            let album = try await library.makeAlbum(named: name)
            albums.append(album)
            return album
        } catch {
            notice = Self.problem(error, doing: "make that album")
            return nil
        }
    }

    public func rename(_ album: PhotoAlbum, to name: String) async {
        guard let library else { return }
        do {
            let renamed = try await library.rename(album, to: name)
            if let index = albums.firstIndex(where: { $0.id == album.id }) { albums[index] = renamed }
        } catch {
            notice = Self.problem(error, doing: "rename that album")
        }
    }

    public func deleteAlbum(_ album: PhotoAlbum) async {
        guard let library else { return }
        do {
            try await library.deleteAlbum(album)
            albums.removeAll { $0.id == album.id }
        } catch {
            notice = Self.problem(error, doing: "delete that album")
        }
    }

    public func album(_ id: UUID) -> PhotoAlbum? {
        albums.first { $0.id == id }
    }

    /// What went wrong, in words for the person.
    nonisolated static func problem(_ error: Error, doing action: String) -> String {
        switch error {
        case SealedStoreError.offline:
            "Photos couldn't \(action), because the server can't be reached. Try again when you're online."
        case PhotoError.changedElsewhere:
            "Photos couldn't \(action), because another device kept changing it. Try again."
        case PhotoError.emptyName:
            "An album needs a name."
        case PhotoError.missing:
            "That photo isn't there any more. It may have been deleted on another device."
        default:
            "Photos couldn't \(action). Try again in a moment."
        }
    }

    // MARK: Sharing

    /// The most one share sends, so an album can't turn into hundreds of messages by accident.
    public nonisolated static let shareLimit = 50

    /// What a share would send, and what it leaves out, before the person confirms it.
    public struct SharePlan: Equatable {
        public let items: [PhotoItem]
        public let tooLong: Int
        public let overLimit: Int
    }

    public func sharePlan(_ chosen: [PhotoItem]) -> SharePlan {
        let longest = sender?.longestVideo ?? 0
        // Only what's still in the library, as it is now. Recently Deleted is never shared.
        let present = chosen.compactMap { self.current($0) }.filter { $0.details.trashed == nil }
        let fits = present.filter { !$0.details.isVideo || ($0.details.duration ?? .infinity) <= longest + 0.5 }
        return SharePlan(
            items: Array(fits.prefix(Self.shareLimit)),
            tooLong: present.count - fits.count,
            overLimit: max(fits.count - Self.shareLimit, 0)
        )
    }

    /// Sends a copy of each photo to `username` in an encrypted chat. Videos go as videos, and a Live
    /// Photo as its still. A shared album is a snapshot: its name first, then its photos. `nil` means it
    /// all went; otherwise the words say what didn't.
    public func share(_ chosen: [PhotoItem], albumName: String? = nil, to username: String) async -> String? {
        guard let sender else { return "Sharing isn't available here." }
        if let reason = sender.unavailableReason { return reason }
        guard sharing == nil else { return "A share is still going. Wait for it to finish." }
        let plan = sharePlan(chosen)
        guard !plan.items.isEmpty else {
            return plan.tooLong > 0 ? Self.tooLongNotice(sender.longestVideo) : "There's nothing here to share."
        }
        let loaders: [@Sendable () async throws -> OutgoingItem] = plan.items.map { item in
            if item.details.isVideo {
                return { [self] in .video(try await exportMovie(item)) }
            }
            return { [self] in .photo(try await original(item)) }
        }
        let note = albumName.map { name in
            plan.items.count == 1 ? "\(name), 1 photo" : "\(name), \(plan.items.count) photos"
        }
        sharing = (0, plan.items.count)
        lastShareSent = 0
        defer { sharing = nil }
        let result = await sender.send(loaders, note: note, to: username) { [weak self] done in
            self?.sharing = (done, plan.items.count)
        }
        lastShareSent = result.sent
        return Self.shareNotice(result, plan: plan, longest: sender.longestVideo)
    }

    nonisolated static func tooLongNotice(_ longest: Double) -> String {
        "Videos over \(longest == 60 ? "a minute" : durationText(longest)) can't be shared in a chat."
    }

    nonisolated static func shareNotice(_ result: PersonSendResult, plan: SharePlan, longest: Double) -> String? {
        var parts: [String] = []
        if result.failed > 0 || (result.sent == 0 && result.problem != nil) {
            let failed = max(result.failed, plan.items.count - result.sent)
            parts.append(failed == 1 ? "One item wasn't sent." : "\(failed) items weren't sent.")
            if let problem = result.problem { parts.append(problem) }
        }
        if plan.tooLong > 0 { parts.append(plan.tooLong == 1 ? "One video was too long to share." : "\(plan.tooLong) videos were too long to share.") }
        if plan.overLimit > 0 { parts.append("Only the first \(shareLimit) were sent. Share the rest separately.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Saving out

    /// The original, for saving to the device's own Photos.
    public func original(_ item: PhotoItem) async throws -> Data {
        guard let library else { throw PhotoError.closed }
        return try await library.original(of: item)
    }

    /// A video or a Live Photo's movement, to play a piece at a time.
    public func movie(_ item: PhotoItem) async throws -> ChunkedCipher.Reader {
        guard let library else { throw PhotoError.closed }
        return try await library.movie(of: item)
    }

    /// The movie as a plain file, for saving to the device's Photos. The caller removes it.
    public func exportMovie(_ item: PhotoItem) async throws -> URL {
        let reader = try await movie(item)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("totality-\(UUID().uuidString).mov")
        do {
            try await Task.detached(priority: .userInitiated) { try reader.copyPlain(to: file) }.value
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    /// Plain copies Totality made for a moment, of a picked video or one being saved to Photos. Each is
    /// removed when it's done with, so any still here are from a time Totality was stopped partway.
    nonisolated static func removeLeftoverPlainFiles(in folder: URL = FileManager.default.temporaryDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("totality-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The camera and place, read from the original on this device.
    public func info(_ item: PhotoItem) async -> PhotoImport.Info? {
        guard !item.details.isVideo else { return nil }
        guard let data = try? await original(item) else { return nil }
        return await Task.detached(priority: .userInitiated) { PhotoImport.info(from: data) }.value
    }

    // MARK: Images

    public func cachedThumbnail(_ item: PhotoItem) -> CGImage? {
        thumbnails[item.id]
    }

    public func thumbnail(_ item: PhotoItem) async -> CGImage? {
        if let held = thumbnails[item.id] { return held }
        guard let library, let data = try? await library.thumbnail(of: item),
              let image = PhotoImport.image(from: data, side: PhotoImport.thumbnailSide)
        else { return nil }
        keep(image, for: item.id)
        return image
    }

    /// The photo at screen size, from its original.
    public func fullImage(_ item: PhotoItem, side: Int) async throws -> CGImage {
        guard let library else { throw PhotoError.closed }
        let data = try await library.original(of: item)
        let image = await Task.detached(priority: .userInitiated) { PhotoImport.image(from: data, side: side) }.value
        guard let image else { throw PhotoError.notAPhoto }
        return image
    }

    private func keep(_ image: CGImage, for id: UUID) {
        if thumbnails[id] == nil { thumbnailOrder.append(id) }
        thumbnails[id] = image
        while thumbnailOrder.count > Self.thumbnailsKept {
            thumbnails[thumbnailOrder.removeFirst()] = nil
        }
    }

    // MARK: Shaping

    public func items(in scope: Scope) -> [PhotoItem] {
        Self.items(items, in: scope, albums: Set(albums.map(\.id)))
    }

    nonisolated static func items(_ items: [PhotoItem], in scope: Scope, albums: Set<UUID>) -> [PhotoItem] {
        switch scope {
        case .library: items.filter { $0.details.trashed == nil }
        case .favourites: items.filter { $0.details.trashed == nil && $0.details.favourite }
        case .videos: items.filter { $0.details.trashed == nil && $0.details.isVideo }
        case .recentlyDeleted:
            items.filter { $0.details.trashed != nil }.sorted { ($0.details.trashed ?? .distantPast) > ($1.details.trashed ?? .distantPast) }
        case .album(let id):
            albums.contains(id) ? items.filter { $0.details.trashed == nil && $0.details.albumIDs.contains(id) } : []
        }
    }

    /// A scope's photos by month, newest first, for the grid's labels.
    public func months(in scope: Scope) -> [Month] {
        Self.months(of: items(in: scope), calendar: .current)
    }

    public func title(of scope: Scope) -> String {
        switch scope {
        case .library: "Library"
        case .favourites: "Favourites"
        case .videos: "Videos"
        case .recentlyDeleted: "Recently Deleted"
        case .album(let id): album(id)?.name ?? "Album"
        }
    }

    /// A video's length, like 1:05 or 10:00.
    nonisolated static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// How long until a photo in Recently Deleted goes for good.
    nonisolated static func daysLeft(_ item: PhotoItem, now: Date = Date()) -> Int? {
        guard let trashed = item.details.trashed else { return nil }
        let left = trashed.addingTimeInterval(Double(PhotoLibrary.trashDays) * 86_400).timeIntervalSince(now)
        return max(0, Int((left / 86_400).rounded(.up)))
    }

    static func months(of items: [PhotoItem], calendar: Calendar) -> [Month] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        var months: [Month] = []
        var current: (key: String, items: [PhotoItem])?
        for item in items {
            let parts = calendar.dateComponents([.year, .month], from: item.date)
            let key = "\(parts.year ?? 0)-\(parts.month ?? 0)"
            if current?.key != key {
                if let current { months.append(Month(id: current.key, title: formatter.string(from: current.items[0].date), items: current.items)) }
                current = (key, [])
            }
            current?.items.append(item)
        }
        if let current { months.append(Month(id: current.key, title: formatter.string(from: current.items[0].date), items: current.items)) }
        return months
    }

    /// How much space is used, as the bottom of the library says it.
    public var usageLine: String? {
        guard let usage else { return nil }
        let format = ByteCountFormatStyle(style: .file)
        return "Using \(usage.used.formatted(format)) of \(usage.limit.formatted(format))"
    }

    public var waitingLine: String? {
        guard waitingCount > 0 else { return nil }
        let count = waitingCount == 1 ? "1 photo" : "\(waitingCount) photos"
        if isFull {
            return "\(count) waiting. Your space is full, so nothing more can upload. Delete photos or videos you don't need and empty Recently Deleted to make room."
        }
        if isOffline { return "\(count) waiting to upload when you're back online." }
        return "Uploading \(count)…"
    }

    public var glance: ModuleGlance? {
        guard library != nil, phase == .ready else { return nil }
        let shown = items(in: .library)
        guard let newest = shown.first else { return ModuleGlance(lines: ["No photos yet"], isQuiet: true) }
        let count = shown.count == 1 ? "1 photo" : "\(shown.count) photos"
        return ModuleGlance(lines: [count, "Newest from \(newest.date.formatted(date: .abbreviated, time: .omitted))"])
    }

    /// The newest photos in the library, for the home tile. Recently Deleted is left out.
    public func newest(_ count: Int) -> [PhotoItem] {
        Array(items(in: .library).prefix(max(count, 0)))
    }

    /// Takes the home tile's request, if the photo is still in the library.
    public func takeRequest() -> UUID? {
        guard let id = requestedItem else { return nil }
        requestedItem = nil
        return items(in: .library).contains { $0.id == id } ? id : nil
    }

    public func change(columnsBy step: Int) {
        let next = min(max(columns + step, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        guard next != columns else { return }
        columns = next
    }
}
