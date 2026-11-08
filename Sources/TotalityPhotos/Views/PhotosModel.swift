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
        case library, favourites, recentlyDeleted
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
    public private(set) var albums: [PhotoAlbum] = []
    public private(set) var usage: SealedStoreUsage?
    public private(set) var waitingCount = 0
    public private(set) var isFull = false
    public private(set) var isOffline = false
    public private(set) var isAdding = false
    public private(set) var unreadable = 0
    public var notice: String?
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
    private let unavailable: (title: String, detail: String)
    private var thumbnails: [UUID: CGImage] = [:]
    private var thumbnailOrder: [UUID] = []
    private static let thumbnailsKept = 400

    /// With no library, Photos explains why, in `unavailable`'s words.
    public init(library: PhotoLibrary?, unavailable: (title: String, detail: String) = PhotosModel.signedOut) {
        self.library = library
        self.unavailable = unavailable
        if library == nil { phase = .unavailable(title: unavailable.title, detail: unavailable.detail) }
    }

    public static let signedOut = (
        title: "Sign in to use Photos",
        detail: "Photos are kept sealed in your account, so Photos needs you signed in on a device that has joined your recovery key."
    )

    public var account: String? { library?.account }

    // MARK: Loading

    public func load() async {
        guard let library else { return }
        do {
            let listing = try await library.list()
            items = listing.items
            unreadable = listing.unreadable
            isOffline = !listing.isCurrent
            waitingCount = listing.items.filter(\.isWaiting).count
            phase = .ready
            albums = try await library.albums().albums
        } catch PhotoError.closed {
            // The account changed under this library, so nothing of it stays on screen.
            items = []
            albums = []
            thumbnails = [:]
            phase = .unavailable(title: "Photos are closed", detail: "These photos belong to another account. Sign in as that account to see them.")
            return
        } catch {
            if items.isEmpty {
                phase = .unavailable(title: "Photos couldn't open", detail: "Something went wrong reading this device's copy. Try again in a moment.")
            }
            return
        }
        usage = try? await library.usage()
        await upload()
    }

    /// Sends what's waiting, and says what's stopping it.
    public func upload() async {
        guard let library else { return }
        let report = await library.upload()
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

    // MARK: Adding

    /// Adds the photos the person picked. `files` loads each one, so the picker's items never reach here.
    public func add(_ files: [@Sendable () async throws -> Data?]) async {
        guard let library, !files.isEmpty else { return }
        isAdding = true
        defer { isAdding = false }
        var added: [PhotoItem] = []
        var skipped = 0
        var tooBig = 0
        for file in files {
            do {
                guard let data = try await file() else {
                    skipped += 1
                    continue
                }
                added.append(try await library.add(data))
            } catch PhotoError.tooBig {
                tooBig += 1
            } catch {
                skipped += 1
            }
        }
        if !added.isEmpty {
            items = (added + items).sorted { $0.date != $1.date ? $0.date > $1.date : $0.id.uuidString < $1.id.uuidString }
            waitingCount = items.filter(\.isWaiting).count
            if phase != .ready { phase = .ready }
        }
        notice = Self.addNotice(skipped: skipped, tooBig: tooBig)
        await upload()
    }

    nonisolated static func addNotice(skipped: Int, tooBig: Int) -> String? {
        var parts: [String] = []
        if tooBig > 0 {
            parts.append(tooBig == 1 ? "One photo is over 100 MB, so it wasn't added." : "\(tooBig) photos are over 100 MB, so they weren't added.")
        }
        if skipped > 0 {
            parts.append(skipped == 1 ? "One item couldn't be read as a photo." : "\(skipped) items couldn't be read as photos.")
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

    // MARK: Saving out

    /// The original, for saving to the device's own Photos.
    public func original(_ item: PhotoItem) async throws -> Data {
        guard let library else { throw PhotoError.closed }
        return try await library.original(of: item)
    }

    /// The camera and place, read from the original on this device.
    public func info(_ item: PhotoItem) async -> PhotoImport.Info? {
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
        case .recentlyDeleted: "Recently Deleted"
        case .album(let id): album(id)?.name ?? "Album"
        }
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
        if isFull { return "\(count) waiting. Your space is full, so nothing more can upload." }
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

    public func change(columnsBy step: Int) {
        let next = min(max(columns + step, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        guard next != columns else { return }
        columns = next
    }
}
