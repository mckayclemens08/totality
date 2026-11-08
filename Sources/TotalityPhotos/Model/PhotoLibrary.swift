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
    public static let sealedPurposes: [String: KeyPurpose] = [
        ".thumb": .photoThumbnail, ".details": .photoDetails,
        ".waiting-original": .photo, ".waiting-thumb": .photoThumbnail, ".waiting-details": .photoDetails,
    ]

    public nonisolated let account: String
    private let sealer: PhotoSealer
    private let cache: any BlobStore
    private let rows: any PhotoRows
    private let store: any SealedStore
    private let clock: @Sendable () -> Date
    private var isClosed = false
    private var isUploading = false

    public init(
        account: String, rootKey: ContentRootKey, cache: any BlobStore, rows: any PhotoRows, store: any SealedStore,
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

    // MARK: Adding

    /// Seals a photo and keeps it on the device, ready to upload. Returns it as it'll show.
    public func add(_ data: Data) throws -> PhotoItem {
        try checkOpen()
        let prepared = try PhotoImport.prepare(data)
        let id = UUID()
        // Whole seconds, which is what the sealed details keep, so the photo shows the same before and after.
        let added = Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
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
        let name = details.id.uuidString.lowercased()
        guard let original = try cache.read("\(name).waiting-original"), let thumbnail = try cache.read("\(name).waiting-thumb"),
              let sealedDetails = try cache.read("\(name).waiting-details")
        else { throw PhotoError.missing }
        try await store.put(original, as: details.original)
        try checkOpen()
        try await store.put(thumbnail, as: details.thumbnail)
        try checkOpen()
        let row = PhotoRow(id: details.id, details: sealedDetails, byteCount: original.count + thumbnail.count + sealedDetails.count)
        try await rows.insert(row, original: details.original)
        // A library closed meanwhile writes nothing more: its key may already have moved on.
        try checkOpen()
        // It's on the server now, so the device keeps what any device would, and the rest goes.
        try cache.write(thumbnail, as: "\(name).thumb")
        try cache.write(sealedDetails, as: "\(name).details")
        try cache.delete("\(name).waiting-original")
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
            let listed = try await rows.list()
            try checkOpen()
            var onServer = Set<UUID>()
            for row in listed where !waitingIDs.contains(row.id) {
                guard let details = try? sealer.openDetails(row.details, of: row.id, account: account) else {
                    unreadable += 1
                    continue
                }
                onServer.insert(row.id)
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
            items += cachedDetails().filter { !waitingIDs.contains($0.id) }.map { PhotoItem(details: $0, isWaiting: false) }
        }
        items.sort { $0.date != $1.date ? $0.date > $1.date : $0.id.uuidString < $1.id.uuidString }
        return PhotoListing(items: items, unreadable: unreadable, isCurrent: isCurrent)
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

    /// The server no longer has these, so neither does the device. Only this account's photos are
    /// forgotten, and waiting photos are never touched.
    private func forget(except kept: Set<UUID>) {
        for name in (try? cache.names()) ?? [] where name.hasSuffix(".details") && !name.hasSuffix(".waiting-details") {
            guard let id = UUID(uuidString: String(name.dropLast(".details".count))), !kept.contains(id),
                  let sealed = try? cache.read(name), (try? sealer.openDetails(sealed, of: id, account: account)) != nil
            else { continue }
            try? cache.delete("\(id.uuidString.lowercased()).thumb")
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
        if let sealed = try cache.read("\(item.id.uuidString.lowercased()).waiting-original") {
            return try sealer.open(sealed, .original, of: item.id)
        }
        let limit = min(max(item.details.byteCount, 0), PhotoImport.maxBytes) + Self.sealingRoom
        guard let sealed = try await fetch(item.details.original, atMost: limit) else { throw PhotoError.missing }
        try checkOpen()
        return try sealer.open(sealed, .original, of: item.id)
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

    public func usage() async throws -> SealedStoreUsage {
        try checkOpen()
        return try await store.usage()
    }
}
