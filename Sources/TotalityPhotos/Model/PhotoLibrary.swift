import Foundation
import TotalityCore

/// What `PhotoLibrary.upload` got done.
public struct PhotoUploadReport: Sendable, Equatable {
    public var sent = 0
    public var waiting = 0
    /// Stopped because the account's space, or the server's, is used up.
    public var full = false
    /// Stopped because the server couldn't be reached.
    public var offline = false

    public init(sent: Int = 0, waiting: Int = 0, full: Bool = false, offline: Bool = false) {
        self.sent = sent
        self.waiting = waiting
        self.full = full
        self.offline = offline
    }
}

public struct AlbumListing: Sendable, Equatable {
    /// Oldest first, the order they were made.
    public let albums: [PhotoAlbum]
    /// False when the server couldn't be reached, so this is what the device last saw.
    public let isCurrent: Bool
}

public struct PhotoListing: Sendable, Equatable {
    /// Newest first.
    public let items: [PhotoItem]
    /// Rows whose details don't open with this device's key.
    public let unreadable: Int
    /// False when the server couldn't be reached, so this is what the device last saw.
    public let isCurrent: Bool
}

/// One account's photos. Everything is sealed on the device before it goes anywhere (non-negotiable 2):
/// the original and its thumbnail go to the sealed store, and a row holding the sealed details goes to
/// the server. Thumbnails and details are kept sealed on the device as well, so the library opens offline.
/// Originals are fetched when they're opened.
///
/// A photo someone adds is written to the device first, all three parts sealed, and only then uploaded.
/// The row goes last, so the server never names a photo whose files aren't there, and nothing is lost
/// if the upload stops partway. The next upload starts that photo again.
///
/// One library per account. Only photos whose sealed details name this account are ever shown.
public actor PhotoLibrary {
    /// How each kind of file here is sealed, so a key change can reach them without knowing what they are.
    /// Movies are in `chunkedPurposes` instead, because they're re-sealed a chunk at a time.
    /// Files sealed in chunks, which a key move re-seals a chunk at a time.
    public static let chunkedPurposes: [String: KeyPurpose] = [".waiting-video": .photoVideo, ".video": .photoVideo]

    public static let sealedPurposes: [String: KeyPurpose] = [
        ".thumb": .photoThumbnail, ".details": .photoDetails,
        ".waiting-original": .photo, ".waiting-thumb": .photoThumbnail, ".waiting-details": .photoDetails,
        ".deleting": .photoDetails, ".album": .photoAlbum, ".iphone-sync": .photoSync, ".google-import": .photoGoogleImport,
    ]
    /// How long a photo stays in Recently Deleted.
    public static let trashDays = 30
    /// How many times a change is tried against another device's changes before giving up.
    static let changeTries = 3

    public nonisolated let account: String
    private let sealer: PhotoSealer
    private let cache: FileBlobStore
    private let rows: any PhotoRows
    private let store: any SealedStore
    private let clock: @Sendable () -> Date
    private var isClosed = false
    private var isUploading = false
    /// Each row's size as the server last said, so a change keeps it right.
    private var rowSizes: [UUID: Int] = [:]
    /// When the server last changed each row, by its clock.
    private var rowChanged: [UUID: Date] = [:]
    /// The photo being uploaded right now. Changing or deleting it waits until it's done, so neither is
    /// overwritten by the copy already on its way.
    private var sending: Set<UUID> = []

    public init(
        account: String, rootKey: ContentRootKey, cache: FileBlobStore, rows: any PhotoRows, store: any SealedStore,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        sealer = PhotoSealer(rootKey: rootKey)
        self.cache = cache
        self.rows = rows
        self.store = store
        self.clock = clock
    }

    /// Nothing more is read or written through this library. The account or the key changed.
    public func close() {
        isClosed = true
    }

    private func checkOpen() throws {
        if isClosed { throw PhotoError.closed }
    }

    // MARK: iPhone sync's record

    /// What iPhone sync has brought in on this device, sealed, under this account's own name, so another
    /// account on the device starts with its own. It's kept even after a photo is deleted here, so sync
    /// never brings back what the person removed.
    public func syncRecord() throws -> SyncRecord {
        try checkOpen()
        guard let id = UUID(uuidString: account), let sealed = try cache.read("\(account).iphone-sync") else { return SyncRecord() }
        let plain = try sealer.open(sealed, .sync, of: id)
        guard let record = try? JSONDecoder.syncRecord.decode(SyncRecord.self, from: plain), record.account == account else {
            throw PhotoError.cantOpen
        }
        return record
    }

    /// Reads, changes and saves the record in one step, so a sync run and a settings change can't lose
    /// each other's changes.
    @discardableResult
    public func updateSyncRecord(_ change: @Sendable (inout SyncRecord) -> Void) throws -> SyncRecord {
        // A record that won't open (after a key mishap, say) is started again rather than leaving sync
        // stuck. Only the list of what came in is lost, so a later run could bring some of it again.
        var record: SyncRecord
        do {
            record = try syncRecord()
        } catch PhotoError.cantOpen {
            record = SyncRecord()
        }
        change(&record)
        try saveSyncRecord(record)
        return record
    }

    private var isSyncing = false

    // MARK: Google Photos import's record

    /// Which Google items have come in for this account, sealed, so none comes twice.
    public func googleRecord() throws -> GoogleImportRecord {
        try checkOpen()
        guard let id = UUID(uuidString: account), let sealed = try cache.read("\(account).google-import") else { return GoogleImportRecord() }
        let plain = try sealer.open(sealed, .googleImport, of: id)
        guard let record = try? JSONDecoder.syncRecord.decode(GoogleImportRecord.self, from: plain), record.account == account else {
            throw PhotoError.cantOpen
        }
        return record
    }

    @discardableResult
    public func updateGoogleRecord(_ change: @Sendable (inout GoogleImportRecord) -> Void) throws -> GoogleImportRecord {
        var record: GoogleImportRecord
        do {
            record = try googleRecord()
        } catch PhotoError.cantOpen {
            record = GoogleImportRecord()
        }
        change(&record)
        record.account = account
        guard let id = UUID(uuidString: account) else { throw PhotoError.cantOpen }
        try cache.write(try sealer.seal(try JSONEncoder.syncRecord.encode(record), .googleImport, of: id), as: "\(account).google-import")
        return record
    }

    /// One sync run at a time for this library, however many screens ask.
    func beginSync() -> Bool {
        guard !isClosed, !isSyncing else { return false }
        isSyncing = true
        return true
    }

    func endSync() {
        isSyncing = false
    }

    /// Removes the record, when sync was turned off having brought nothing, so a device whose only
    /// sealed file is an unused record can still be handed on as empty.
    func removeSyncRecordIfUnused() throws {
        try checkOpen()
        guard let record = try? syncRecord(), !record.isOn, record.synced.isEmpty, record.skipped.isEmpty else { return }
        try cache.delete("\(account).iphone-sync")
    }

    public func saveSyncRecord(_ record: SyncRecord) throws {
        try checkOpen()
        guard let id = UUID(uuidString: account) else { throw PhotoError.cantOpen }
        var record = record
        record.account = account
        let plain = try JSONEncoder.syncRecord.encode(record)
        try cache.write(try sealer.seal(plain, .sync, of: id), as: "\(account).iphone-sync")
    }

    // MARK: Adding

    /// Seals a photo and keeps it on the device, ready to upload. Returns it as it'll show.
    public func add(_ data: Data) throws -> PhotoItem {
        try checkOpen()
        let prepared = try PhotoImport.prepare(data)
        let id = UUID()
        let added = wholeSeconds(clock())
        let details = PhotoDetails(
            id: id, owner: account, original: UUID(), thumbnail: UUID(), added: added, taken: prepared.taken,
            width: prepared.width, height: prepared.height, type: prepared.type, byteCount: data.count
        )
        let name = id.uuidString.lowercased()
        try cache.write(try sealer.seal(data, .original, of: id), as: "\(name).waiting-original")
        try cache.write(try sealer.seal(prepared.thumbnail, .thumbnail, of: id), as: "\(name).waiting-thumb")
        // The details go last, because they're what makes a waiting photo count.
        try cache.write(try sealer.sealDetails(details), as: "\(name).waiting-details")
        return PhotoItem(details: details, isWaiting: true)
    }

    /// Seals a video from its file and keeps it on the device, ready to upload. The file isn't changed or
    /// removed: whoever made it removes it.
    public func addVideo(_ file: URL) async throws -> PhotoItem {
        try checkOpen()
        let prepared = try await VideoImport.prepare(file)
        try checkOpen()
        let id = UUID()
        var details = PhotoDetails(
            id: id, owner: account, original: UUID(), thumbnail: UUID(), added: wholeSeconds(clock()), taken: prepared.taken,
            width: prepared.width, height: prepared.height, type: prepared.type, byteCount: prepared.byteCount
        )
        details.media = .video
        details.duration = prepared.duration
        let name = id.uuidString.lowercased()
        do {
            try sealer.sealMovie(file, to: cache.location(of: "\(name).waiting-video"), of: id)
            // Sealing a long video takes a while. A library closed meanwhile keeps nothing of it.
            try checkOpen()
            try cache.write(try sealer.seal(prepared.thumbnail, .thumbnail, of: id), as: "\(name).waiting-thumb")
            try cache.write(try sealer.sealDetails(details), as: "\(name).waiting-details")
        } catch {
            discardWaiting(name)
            throw error
        }
        return PhotoItem(details: details, isWaiting: true)
    }

    /// What a failed add left behind, which has no details to make it count.
    private func discardWaiting(_ name: String) {
        for suffix in [".waiting-details", ".waiting-original", ".waiting-video", ".waiting-thumb"] { try? cache.delete(name + suffix) }
    }

    /// A Live Photo: its still, as any photo, and its few seconds of movement, sealed in chunks.
    public func addLive(still: Data, motion: URL) async throws -> PhotoItem {
        try checkOpen()
        let prepared = try PhotoImport.prepare(still)
        let motionBytes = (try? motion.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard motionBytes > 0, motionBytes <= VideoImport.maxBytes else { throw PhotoError.notAPhoto }
        let duration = await VideoImport.duration(of: motion)
        try checkOpen()
        let id = UUID()
        var details = PhotoDetails(
            id: id, owner: account, original: UUID(), thumbnail: UUID(), added: wholeSeconds(clock()), taken: prepared.taken,
            width: prepared.width, height: prepared.height, type: prepared.type, byteCount: still.count
        )
        details.media = .live
        details.motion = UUID()
        details.motionByteCount = motionBytes
        details.duration = duration
        let name = id.uuidString.lowercased()
        do {
            try cache.write(try sealer.seal(still, .original, of: id), as: "\(name).waiting-original")
            try sealer.sealMovie(motion, to: cache.location(of: "\(name).waiting-video"), of: id)
            try checkOpen()
            try cache.write(try sealer.seal(prepared.thumbnail, .thumbnail, of: id), as: "\(name).waiting-thumb")
            try cache.write(try sealer.sealDetails(details), as: "\(name).waiting-details")
        } catch {
            discardWaiting(name)
            throw error
        }
        return PhotoItem(details: details, isWaiting: true)
    }

    /// Whole seconds, which is what the sealed details keep, so a photo shows the same before and after.
    private func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Photos added here and not uploaded yet, oldest first.
    func waiting() throws -> [PhotoDetails] {
        try cache.names().compactMap { name -> PhotoDetails? in
            guard name.hasSuffix(".waiting-details"), let id = UUID(uuidString: String(name.dropLast(".waiting-details".count))),
                  let sealed = try cache.read(name)
            else { return nil }
            return try? sealer.openDetails(sealed, of: id, account: account)
        }
        .sorted { $0.added < $1.added }
    }

    /// Uploads what's waiting, one photo at a time, and stops at the first thing that needs the person
    /// or the network. Safe to call again at any point.
    public func upload() async -> PhotoUploadReport {
        var report = PhotoUploadReport()
        guard !isClosed, !isUploading, let waiting = try? waiting() else { return report }
        isUploading = true
        defer { isUploading = false }
        await finishDeletions()
        report.waiting = waiting.count
        for details in waiting {
            guard !isClosed else { break }
            do {
                try await send(details)
                report.sent += 1
                report.waiting -= 1
            } catch SealedStoreError.full {
                report.full = true
                break
            } catch SealedStoreError.offline {
                report.offline = true
                break
            } catch PhotoError.closed {
                break
            } catch is PhotoRowsWrongAccount {
                close()
                break
            } catch {
                // Anything else is tried again next time, so one bad photo doesn't stop the rest.
                continue
            }
        }
        return report
    }

    private func send(_ details: PhotoDetails) async throws {
        sending.insert(details.id)
        defer { sending.remove(details.id) }
        let name = details.id.uuidString.lowercased()
        guard let thumbnail = try cache.read("\(name).waiting-thumb"), let sealedDetails = try cache.read("\(name).waiting-details")
        else { throw PhotoError.missing }
        var size = thumbnail.count + sealedDetails.count
        if let movie = details.movie {
            // Checked before it goes, so a movie a key change left behind is never uploaded unopenable.
            let file = try cache.location(of: "\(name).waiting-video")
            _ = try sealer.openMovie(file, of: details.id)
            try await store.putFile(file, as: movie.blob)
            try checkOpen()
            size += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        if !details.isVideo {
            guard let original = try cache.read("\(name).waiting-original") else { throw PhotoError.missing }
            try await store.put(original, as: details.original)
            try checkOpen()
            size += original.count
        }
        try await store.put(thumbnail, as: details.thumbnail)
        try checkOpen()
        let row = PhotoRow(id: details.id, details: sealedDetails, byteCount: size)
        try await rows.insert(row, kind: .photo, original: details.original)
        // A library closed meanwhile writes nothing more: its key may already have moved on.
        try checkOpen()
        // It's on the server now, so the device keeps what any device would, and the rest goes.
        try cache.write(thumbnail, as: "\(name).thumb")
        try cache.write(sealedDetails, as: "\(name).details")
        try cache.delete("\(name).waiting-original")
        try cache.delete("\(name).waiting-video")
        try cache.delete("\(name).waiting-thumb")
        try cache.delete("\(name).waiting-details")
    }

    // MARK: Reading

    /// Every photo, newest first: the server's, and what's waiting here. Without the server, it's what
    /// this device saw last, plus what's waiting.
    public func list() async throws -> PhotoListing {
        try checkOpen()
        let waiting = try waiting()
        let waitingIDs = Set(waiting.map(\.id))
        var items = waiting.map { PhotoItem(details: $0, isWaiting: true) }
        var unreadable = 0
        var isCurrent = true
        do {
            let listed = try await rows.list(.photo)
            try checkOpen()
            let deleting = deletingIDs()
            var onServer = Set<UUID>()
            for row in listed where !waitingIDs.contains(row.id) {
                rowSizes[row.id] = row.byteCount
                rowChanged[row.id] = row.changed
                if deleting.contains(row.id) {
                    onServer.insert(row.id)
                    continue
                }
                guard let details = try? sealer.openDetails(row.details, of: row.id, account: account) else {
                    unreadable += 1
                    continue
                }
                onServer.insert(row.id)
                // An older copy than this device has already seen is a server rolling a change back.
                // The device keeps showing the newer one, and the next change starts again from the server's.
                if let kept = cachedDetails(of: row.id), kept.changeCount > details.changeCount {
                    items.append(PhotoItem(details: kept, isWaiting: false))
                    continue
                }
                items.append(PhotoItem(details: details, isWaiting: false))
                try? cache.write(row.details, as: "\(row.id.uuidString.lowercased()).details")
            }
            forget(except: onServer)
        } catch PhotoError.closed {
            throw PhotoError.closed
        } catch is PhotoRowsWrongAccount {
            // Someone else is signed in now, so this account's photos stop here, cached ones included.
            close()
            throw PhotoError.closed
        } catch {
            isCurrent = false
            let deleting = deletingIDs()
            items += cachedDetails().filter { !waitingIDs.contains($0.id) && !deleting.contains($0.id) }
                .map { PhotoItem(details: $0, isWaiting: false) }
        }
        // Anything in Recently Deleted for longer than it keeps things goes for good, by this device's
        // clock and, for anything on the server, by the server's too.
        let now = clock()
        var serverNow: Date?
        if isCurrent, items.contains(where: { !$0.isWaiting && isExpired($0, now: now, serverNow: now) }) {
            serverNow = try? await store.usage().serverTime
        }
        let expired = items.filter { isExpired($0, now: now, serverNow: serverNow) && (isCurrent || $0.isWaiting) }
        if !expired.isEmpty {
            for item in expired { try? await deleteForGood(item) }
            let gone = Set(expired.map(\.id))
            items.removeAll { gone.contains($0.id) }
        }
        items.sort { $0.date != $1.date ? $0.date > $1.date : $0.id.uuidString < $1.id.uuidString }
        return PhotoListing(items: items, unreadable: unreadable, isCurrent: isCurrent)
    }

    /// Whether a photo has been in Recently Deleted long enough to go for good. Deleting for good can't
    /// be undone, so one wrong clock isn't enough. The date it was put there must be after it was added
    /// and not in the future. For a photo on the server, the server's time of that change must agree
    /// with it, and the server's clock now must say the 30 days have passed as well as this device's.
    func isExpired(_ item: PhotoItem, now: Date, serverNow: Date?) -> Bool {
        guard let trashed = item.details.trashed else { return false }
        let keep = Double(Self.trashDays) * 86_400
        let day = 86_400.0
        guard trashed <= now, trashed >= item.details.added - day, now.timeIntervalSince(trashed) >= keep else { return false }
        if item.isWaiting { return true }
        guard let changed = rowChanged[item.id], let serverNow else { return false }
        return abs(changed.timeIntervalSince(trashed)) <= day && serverNow.timeIntervalSince(changed) >= keep
    }

    private func cachedDetails(of id: UUID) -> PhotoDetails? {
        (try? cache.read("\(id.uuidString.lowercased()).details")).flatMap { $0 }
            .flatMap { try? sealer.openDetails($0, of: id, account: account) }
    }

    /// Waits for an upload of this photo to finish.
    private func waitUntilSent(_ id: UUID) async throws {
        while sending.contains(id) {
            try await Task.sleep(for: .milliseconds(50))
            try checkOpen()
        }
    }

    /// What this device kept from the last listing.
    private func cachedDetails() -> [PhotoDetails] {
        ((try? cache.names()) ?? []).compactMap { name in
            guard name.hasSuffix(".details"), !name.hasSuffix(".waiting-details"),
                  let id = UUID(uuidString: String(name.dropLast(".details".count))), let sealed = try? cache.read(name)
            else { return nil }
            return try? sealer.openDetails(sealed, of: id, account: account)
        }
    }

    /// Photos being deleted for good, which never show again even if their row is still there.
    private func deletingIDs() -> Set<UUID> {
        Set(((try? cache.names()) ?? []).compactMap { name in
            name.hasSuffix(".deleting") ? UUID(uuidString: String(name.dropLast(".deleting".count))) : nil
        })
    }

    /// The server no longer has these, so neither does the device. Only this account's photos are
    /// forgotten, and waiting photos are never touched.
    private func forget(except kept: Set<UUID>) {
        for name in (try? cache.names()) ?? [] where name.hasSuffix(".details") && !name.hasSuffix(".waiting-details") {
            guard let id = UUID(uuidString: String(name.dropLast(".details".count))), !kept.contains(id),
                  let sealed = try? cache.read(name), (try? sealer.openDetails(sealed, of: id, account: account)) != nil
            else { continue }
            try? cache.delete("\(id.uuidString.lowercased()).thumb")
            try? cache.delete("\(id.uuidString.lowercased()).video")
            try? cache.delete(name)
        }
    }

    /// The thumbnail as a JPEG, from the device if it's here, or else from the sealed store.
    public func thumbnail(of item: PhotoItem) async throws -> Data {
        try checkOpen()
        let name = item.id.uuidString.lowercased()
        for local in ["\(name).waiting-thumb", "\(name).thumb"] {
            if let sealed = try cache.read(local), let opened = try? sealer.open(sealed, .thumbnail, of: item.id) { return opened }
        }
        guard let sealed = try await fetch(item.details.thumbnail, atMost: Self.thumbnailLimit) else { throw PhotoError.missing }
        let opened = try sealer.open(sealed, .thumbnail, of: item.id)
        try checkOpen()
        try? cache.write(sealed, as: "\(name).thumb")
        return opened
    }

    /// The original file exactly as it was added.
    public func original(of item: PhotoItem) async throws -> Data {
        try checkOpen()
        // A video is read in pieces, through `movie(of:)`, never whole.
        guard !item.details.isVideo else { throw PhotoError.notAPhoto }
        if let sealed = try cache.read("\(item.id.uuidString.lowercased()).waiting-original") {
            return try sealer.open(sealed, .original, of: item.id)
        }
        let limit = min(max(item.details.byteCount, 0), PhotoImport.maxBytes) + Self.sealingRoom
        guard let sealed = try await fetch(item.details.original, atMost: limit) else { throw PhotoError.missing }
        try checkOpen()
        return try sealer.open(sealed, .original, of: item.id)
    }

    /// A video, or a Live Photo's movement, ready to read in pieces. A waiting one is read from the
    /// device. Otherwise the sealed file is downloaded once and kept, and only the newest few are kept.
    public func movie(of item: PhotoItem) async throws -> ChunkedCipher.Reader {
        try checkOpen()
        guard let movie = item.details.movie else { throw PhotoError.notAPhoto }
        let name = item.id.uuidString.lowercased()
        let waiting = try cache.location(of: "\(name).waiting-video")
        if FileManager.default.fileExists(atPath: waiting.path) { return try sealer.openMovie(waiting, of: item.id) }
        let kept = try cache.location(of: "\(name).video")
        if FileManager.default.fileExists(atPath: kept.path) {
            if let reader = try? sealer.openMovie(kept, of: item.id) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: kept.path)
                return reader
            }
            try? cache.delete("\(name).video")
        }
        // One download of a movie at a time. Anyone else asking for it waits for that one.
        if let running = downloads[item.id] {
            try await running.value
        } else {
            let task = Task { try await self.fetchMovie(item, blob: movie.blob, byteCount: movie.byteCount) }
            downloads[item.id] = task
            defer { downloads[item.id] = nil }
            try await task.value
        }
        try checkOpen()
        return try sealer.openMovie(kept, of: item.id)
    }

    /// Movies being downloaded now, one task each.
    private var downloads: [UUID: Task<Void, Error>] = [:]

    private func fetchMovie(_ item: PhotoItem, blob: UUID, byteCount: Int) async throws {
        let name = item.id.uuidString.lowercased()
        let part = try cache.location(of: "\(name).video-part")
        let limit = ChunkedCipher.sealedLength(plain: min(max(byteCount, 0), VideoImport.maxBytes))
        let found: Bool
        do {
            found = try await store.download(blob, to: part, limit: limit)
        } catch SealedStoreError.tooBig {
            // More than this movie can be: not this photo's, so nothing of it is kept to carry on from.
            try? cache.delete("\(name).video-part")
            throw PhotoError.tooBig
        }
        guard found else { throw PhotoError.missing }
        try checkOpen()
        do {
            // Every chunk is checked once, so nothing damaged anywhere is kept to fail partway through playing.
            try sealer.openMovie(part, of: item.id).verifyAll()
        } catch {
            // Damaged or not this photo's: thrown away, so the next try starts clean.
            try? cache.delete("\(name).video-part")
            throw PhotoError.cantOpen
        }
        try? cache.delete("\(name).video")
        try FileManager.default.moveItem(at: part, to: try cache.location(of: "\(name).video"))
        trimMovies(keeping: name)
    }

    /// How many downloaded movies stay on the device. They're sealed, but big.
    static let moviesKept = 3

    private func trimMovies(keeping current: String) {
        // Partial downloads nobody is finishing, and leftovers from a key move cut off partway.
        let busy = Set(downloads.keys.map { "\($0.uuidString.lowercased()).video-part" })
        for name in (try? cache.names()) ?? [] where (name.hasSuffix(".video-part") && !busy.contains(name)) || name.hasSuffix("-moving") {
            try? cache.delete(name)
        }
        let movies = ((try? cache.names()) ?? []).filter { $0.hasSuffix(".video") && $0 != "\(current).video" }
        let dated = movies.compactMap { name -> (String, Date)? in
            guard let url = try? cache.location(of: name),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (name, date)
        }
        for (name, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.moviesKept - 1) { try? cache.delete(name) }
    }

    /// Room for what sealing adds to a file, which is far less than this.
    static let sealingRoom = 64 * 1024
    /// A thumbnail is 480 pixels on its longest side, so anything near this is the server misbehaving.
    static let thumbnailLimit = 2 * 1024 * 1024

    /// Downloads a blob only if the server says it's no bigger than it can be, so a misbehaving server
    /// can't fill the device's memory. Opening it checks it's the right one.
    private func fetch(_ id: UUID, atMost limit: Int) async throws -> Data? {
        guard let size = try await store.size(of: id) else { return nil }
        guard size <= limit else { throw PhotoError.tooBig }
        try checkOpen()
        guard let sealed = try await store.get(id) else { return nil }
        guard sealed.count <= limit else { throw PhotoError.tooBig }
        return sealed
    }

    // MARK: Changing

    /// Changes what the person can change about a photo: favourite, caption, albums, Recently Deleted.
    /// The new details are sealed here and replace the server's only if no other device changed them
    /// meanwhile. If one did, the change is made again on top of theirs.
    @discardableResult
    public func change(_ item: PhotoItem, _ edit: @escaping @Sendable (inout PhotoDetails) -> Void) async throws -> PhotoItem {
        try checkOpen()
        try await waitUntilSent(item.id)
        let name = item.id.uuidString.lowercased()
        let apply: (inout PhotoDetails) -> Void = { details in
            edit(&details)
            details.caption = details.caption.map { String($0.prefix(PhotoDetails.captionLimit)) }
            details.revision = details.changeCount + 1
        }
        if let sealed = try cache.read("\(name).waiting-details") {
            var details = try sealer.openDetails(sealed, of: item.id, account: account)
            apply(&details)
            try cache.write(try sealer.sealDetails(details), as: "\(name).waiting-details")
            return PhotoItem(details: details, isWaiting: true)
        }
        guard var current = try cache.read("\(name).details") else { throw PhotoError.missing }
        for _ in 0..<Self.changeTries {
            var details = try sealer.openDetails(current, of: item.id, account: account)
            let seen = details.changeCount
            apply(&details)
            let sealed = try sealer.sealDetails(details)
            let size = max(0, (rowSizes[item.id] ?? details.byteCount + current.count) - current.count + sealed.count)
            let row = PhotoRow(id: item.id, details: sealed, byteCount: size)
            if try await rows.update(row, kind: .photo, replacing: current) {
                try checkOpen()
                rowSizes[item.id] = size
                // The server's time of this change comes with the next listing.
                rowChanged[item.id] = nil
                try cache.write(sealed, as: "\(name).details")
                return PhotoItem(details: details, isWaiting: false)
            }
            // Another device got there first. Start again from what the server has now, unless it's
            // older than what this device has seen, which no other device could have made.
            guard let fresh = try await rows.row(item.id, kind: .photo) else { throw PhotoError.missing }
            try checkOpen()
            guard try sealer.openDetails(fresh.details, of: item.id, account: account).changeCount >= seen else {
                throw PhotoError.changedElsewhere
            }
            rowSizes[item.id] = fresh.byteCount
            rowChanged[item.id] = fresh.changed
            try cache.write(fresh.details, as: "\(name).details")
            current = fresh.details
        }
        throw PhotoError.changedElsewhere
    }

    /// Removes a photo for good: its row, its files, and what this device kept. Safe to stop partway,
    /// because what's left is finished the next time the library uploads.
    public func deleteForGood(_ item: PhotoItem) async throws {
        try checkOpen()
        try await waitUntilSent(item.id)
        let name = item.id.uuidString.lowercased()
        if try cache.read("\(name).waiting-details") != nil {
            // It never reached the server, so the device's copy is all there is.
            try cache.delete("\(name).waiting-details")
            try cache.delete("\(name).waiting-original")
            try cache.delete("\(name).waiting-video")
            try cache.delete("\(name).waiting-thumb")
            return
        }
        // The sealed details name both files, so they're what's kept until both are gone.
        try cache.write(try sealer.sealDetails(item.details), as: "\(name).deleting")
        try await finishDeleting(item.details)
    }

    private func finishDeleting(_ details: PhotoDetails) async throws {
        let name = details.id.uuidString.lowercased()
        // The row goes first, so no device lists a photo whose files are on their way out.
        try await rows.delete(details.id, kind: .photo)
        try await store.delete(details.original)
        try await store.delete(details.thumbnail)
        if let motion = details.motion { try await store.delete(motion) }
        try checkOpen()
        rowSizes[details.id] = nil
        try? cache.delete("\(name).details")
        try? cache.delete("\(name).thumb")
        try? cache.delete("\(name).video")
        try cache.delete("\(name).deleting")
    }

    /// Finishes deletions that stopped partway.
    private func finishDeletions() async {
        for id in deletingIDs() {
            guard !isClosed, let sealed = try? cache.read("\(id.uuidString.lowercased()).deleting"),
                  let details = try? sealer.openDetails(sealed, of: id, account: account)
            else { continue }
            try? await finishDeleting(details)
        }
    }

    // MARK: Albums

    /// The albums this account made. Without the server, what this device saw last.
    public func albums() async throws -> AlbumListing {
        try checkOpen()
        do {
            let listed = try await rows.list(.album)
            try checkOpen()
            var albums: [PhotoAlbum] = []
            for row in listed {
                guard let album = try? sealer.openAlbum(row.details, of: row.id, account: account) else { continue }
                let file = "\(row.id.uuidString.lowercased()).album"
                if let kept = (try? cache.read(file)).flatMap({ $0 }).flatMap({ try? sealer.openAlbum($0, of: row.id, account: account) }),
                   (kept.revision ?? 0) > (album.revision ?? 0) {
                    albums.append(kept)
                    continue
                }
                albums.append(album)
                try? cache.write(row.details, as: file)
            }
            let kept = Set(albums.map(\.id))
            for (id, name) in cachedAlbumNames() where !kept.contains(id) {
                try? cache.delete(name)
            }
            return AlbumListing(albums: albums.sorted(by: Self.albumOrder), isCurrent: true)
        } catch PhotoError.closed {
            throw PhotoError.closed
        } catch is PhotoRowsWrongAccount {
            close()
            throw PhotoError.closed
        } catch {
            let albums = cachedAlbumNames().compactMap { id, name in
                (try? cache.read(name)).flatMap { $0 }.flatMap { try? sealer.openAlbum($0, of: id, account: account) }
            }
            return AlbumListing(albums: albums.sorted(by: Self.albumOrder), isCurrent: false)
        }
    }

    private static func albumOrder(_ a: PhotoAlbum, _ b: PhotoAlbum) -> Bool {
        a.created != b.created ? a.created < b.created : a.id.uuidString < b.id.uuidString
    }

    /// This device's copies of albums. Only ones that open as this account's are ever touched.
    private func cachedAlbumNames() -> [(UUID, String)] {
        ((try? cache.names()) ?? []).compactMap { name in
            guard name.hasSuffix(".album"), let id = UUID(uuidString: String(name.dropLast(".album".count))),
                  let sealed = try? cache.read(name), (try? sealer.openAlbum(sealed, of: id, account: account)) != nil
            else { return nil }
            return (id, name)
        }
    }

    public func makeAlbum(named name: String) async throws -> PhotoAlbum {
        try checkOpen()
        guard let name = PhotoAlbum.tidy(name) else { throw PhotoError.emptyName }
        let album = PhotoAlbum(id: UUID(), owner: account, name: name, created: clock())
        let sealed = try sealer.sealAlbum(album)
        try await rows.insert(PhotoRow(id: album.id, details: sealed, byteCount: sealed.count), kind: .album, original: nil)
        try checkOpen()
        try cache.write(sealed, as: "\(album.id.uuidString.lowercased()).album")
        return album
    }

    public func rename(_ album: PhotoAlbum, to name: String) async throws -> PhotoAlbum {
        try checkOpen()
        guard let name = PhotoAlbum.tidy(name) else { throw PhotoError.emptyName }
        let file = "\(album.id.uuidString.lowercased()).album"
        guard var current = try cache.read(file) else { throw PhotoError.missing }
        for _ in 0..<Self.changeTries {
            var renamed = try sealer.openAlbum(current, of: album.id, account: account)
            let seen = renamed.revision ?? 0
            renamed.name = name
            renamed.revision = seen + 1
            let sealed = try sealer.sealAlbum(renamed)
            if try await rows.update(PhotoRow(id: album.id, details: sealed, byteCount: sealed.count), kind: .album, replacing: current) {
                try checkOpen()
                try cache.write(sealed, as: file)
                return renamed
            }
            guard let fresh = try await rows.row(album.id, kind: .album) else { throw PhotoError.missing }
            try checkOpen()
            guard (try sealer.openAlbum(fresh.details, of: album.id, account: account).revision ?? 0) >= seen else {
                throw PhotoError.changedElsewhere
            }
            current = fresh.details
        }
        throw PhotoError.changedElsewhere
    }

    /// Deletes the album, never its photos. They stay in the library, and the album's ID left in their
    /// sealed details is ignored, since no album has it.
    public func deleteAlbum(_ album: PhotoAlbum) async throws {
        try checkOpen()
        try await rows.delete(album.id, kind: .album)
        try checkOpen()
        try? cache.delete("\(album.id.uuidString.lowercased()).album")
    }

    public func usage() async throws -> SealedStoreUsage {
        try checkOpen()
        return try await store.usage()
    }
}
