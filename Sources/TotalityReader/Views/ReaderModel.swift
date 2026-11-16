import Foundation
import Observation
import TotalityCore

/// What the Reader screens show. All work happens in the vault.
@MainActor
@Observable
public final class ReaderModel {
    public enum Phase: Equatable {
        case loading, ready, failed
    }

    private static let glanceTitles = 5

    public private(set) var phase = Phase.loading
    public private(set) var library = ReaderLibrary()
    public private(set) var trash: [TrashedItem] = []
    public private(set) var unreadable = 0
    public private(set) var hits: [ReaderSearchHit] = []
    public var query = ""
    /// An item another module asked to open. The home screen takes it from here.
    public var requestedItem: UUID?
    /// A Drive file home search found, by its result's ID. The home screen takes it from here.
    public var requestedDriveHit: String?
    /// A doc a wiki link leads to. It opens on top of the doc the link is in, so Back returns there.
    public var linkedItem: UUID?
    /// A heading a wiki link named, for the doc it leads to to jump to once it opens.
    public var linkedHeading: LinkedHeading?
    /// True once this device syncs, which decides what the screen can truthfully say about recovery.
    public var isSynced = false
    /// A problem to show the person, cleared when they dismiss it.
    public var notice: String?
    /// A big file being imported, and how far it's got, for the progress bar.
    public private(set) var importing: ImportProgress?
    /// The journal (issue 128): every day with writing, and the notes added under them.
    public internal(set) var journal = JournalListing.empty
    /// Nil until the journal has been read, and false when it couldn't be.
    public internal(set) var journalLoaded: Bool?
    /// Words in today's entry, for the journal's row.
    public internal(set) var journalTodayWords = 0
    /// How much room is left in the account's storage on the Totality server, or nil when it can't be
    /// told right now. The app sets it, so a file that won't fit is refused before it's sealed.
    public var storageLeft: (@Sendable () async -> Int?)?

    public let listen: ListenController
    /// Linked Google Drive folders (issue 102), or nil when this build has no Google sign-in.
    public var drive: DriveModel?
    /// Where the person stopped in each file, synced as one sealed record (issue 117).
    public var places: ReadingPlaceBook?
    /// Where the person is in the front item, for the home square, such as "Page 112".
    public internal(set) var homePlace: String?
    /// The journal's code, in its own file, reaches the vault too.
    let vault: ReaderVault
    /// The latest item's text and its sentences, made ahead so Listen starts sooner.
    private var prepared: (id: UUID, readHeadings: Bool, split: Task<Result<(String, ListenScript), any Error>, Never>)?

    public init(vault: ReaderVault, listen: ListenController) {
        self.vault = vault
        self.listen = listen
        listen.onPosition = { [vault] id, offset in
            Task { try? await vault.setListenPosition(offset, of: id) }
        }
        refresher.add("device") { [weak self] in
            await self?.load()
            return .done
        }
    }

    /// Brings the library up to date. The app adds the step that syncs with the person's other devices.
    public let refresher = Refresher()

    public var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var items: [ReaderItem] {
        library.items
    }

    /// For the home tile: what's playing, then what was opened last, from the library or Google Drive.
    /// Nil until the library opens, so a tile can't claim it's empty while it's loading.
    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        let shelf = shelf
        guard !shelf.isEmpty else { return ModuleGlance(lines: ["Nothing saved yet"], isQuiet: true) }
        let playing = listen.current
        let recent = glanceTitles(in: shelf, leaving: playing?.id).map(\.title)
        let count = switch items.count {
        case 0: "In Google Drive"
        case 1: "1 item"
        default: "\(items.count) items"
        }
        return ModuleGlance(lines: (playing.map { ["Listening to \($0.title)"] } ?? []) + recent + [count])
    }

    private func glanceTitles(in shelf: [ShelfEntry], leaving playing: UUID?) -> [ShelfEntry] {
        Array(shelf.filter { $0.id != playing }.prefix(Self.glanceTitles))
    }

    /// The entry behind a line of the glance. The last line counts items, so it opens nothing.
    public func glanceItem(at line: Int) -> UUID? {
        let playing = listen.current?.id
        let ids = (playing.map { [$0] } ?? []) + glanceTitles(in: shelf, leaving: playing).map(\.id)
        return ids.indices.contains(line) ? ids[line] : nil
    }

    /// What the home tile puts first: what's playing, or else what was opened last.
    public var frontOfShelf: ShelfEntry? {
        let shelf = shelf
        let playing = listen.current?.id
        return shelf.first { $0.id == playing } ?? items.first { $0.id == playing }.map(ShelfEntry.item) ?? shelf.first
    }

    /// Stops anything that could write, for when every blob is about to be rewritten under a new key.
    public func stopForKeyChange() async {
        listen.stop()
        forgetPrepared()
        await vault.close()
        await drive?.close()
    }

    public func load() async {
        do {
            try? await vault.adoptCollections()
            // Sync does this too, but "30 days" has to hold on a device that's offline.
            try? await vault.emptyOldTrash()
            let listing = try await vault.list()
            library = ReaderLibrary(items: listing.items, folders: listing.folders, opened: listing.opened)
            // Links and opened files can arrive from another device with the library.
            await drive?.load()
            if let id = prepared?.id, !listing.items.contains(where: { $0.id == id }) { forgetPrepared(id) }
            let wasTrashed = Set(trash.map(\.item.id))
            trash = try await vault.trashed()
            // Only what this device saw leave the trash for good loses its place. An item that simply
            // hasn't arrived here yet keeps its place from another device.
            let kept = Set(listing.items.map(\.id)).union(trash.map(\.item.id))
            await forgetPlaces(wasTrashed.subtracting(kept))
            unreadable = listing.unreadable
            await loadJournal()
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    public func search() async {
        guard isSearching else {
            hits = []
            return
        }
        do {
            hits = try await vault.search(query)
        } catch is CancellationError {
            // The person kept typing, and the newer search takes over.
        } catch {
            notice = "Search didn't finish. Try again."
        }
    }

    public func newNote(in folder: UUID? = nil) async -> ReaderItem? {
        do {
            let item = try await vault.createNote(folder: folder)
            await load()
            return item
        } catch {
            notice = "The doc couldn't be created."
            return nil
        }
    }

    public func newFolder(_ title: String, in parent: UUID?) async {
        await change("The folder couldn't be created.") { _ = try await $0.createFolder(title: title, in: parent) }
    }

    public func rename(_ item: ReaderItem, to title: String) async {
        await change("\(item.displayTitle) couldn't be renamed.") { try await $0.rename(item.id, to: title) }
    }

    public func move(_ item: ReaderItem, to folder: UUID?) async {
        do {
            try await vault.move(item.id, to: folder)
            await load()
        } catch let error as ReaderError {
            notice = error.message
        } catch {
            notice = "\(item.displayTitle) couldn't be moved."
        }
    }

    /// For drag and drop, which carries only an ID. Whatever it names has to be here already.
    public func move(id: UUID, to folder: UUID?) async {
        guard let entry = (library.items + library.folders).first(where: { $0.id == id }), library.canMove(entry, to: folder) else { return }
        await move(entry, to: folder)
    }

    public func restore(_ item: ReaderItem) async {
        await change("\(item.displayTitle) couldn't be restored.") { try await $0.restore(item.id) }
    }

    public func deleteForever(_ item: ReaderItem) async {
        await change("\(item.displayTitle) couldn't be deleted.") { try await $0.deleteForever(item.id) }
        await forgetPlaces([item.id])
    }

    public func emptyTrash() async {
        let gone = Set(trash.map(\.item.id))
        await change("Recently Deleted couldn't be emptied.") { try await $0.emptyTrash() }
        await forgetPlaces(gone)
    }

    private func change(_ failure: String, _ work: (ReaderVault) async throws -> Void) async {
        do {
            try await work(vault)
            await load()
        } catch {
            notice = failure
        }
    }

    /// Failing here only costs a place in the list, so it doesn't interrupt the person.
    public func markOpened(_ id: UUID) async {
        let date = Date()
        guard (try? await vault.markOpened(id, at: date)) != nil else { return }
        library = library.opening(id, at: date)
    }

    public func currentItem(_ id: UUID) async throws -> ReaderItem {
        try await vault.item(id)
    }

    public func loadNote(_ id: UUID) async throws -> String {
        String(decoding: try await vault.body(of: id), as: UTF8.self)
    }

    /// A note's Markdown for the writing editor. Opening an older doc converts it, which the library
    /// shows as its kept original appearing.
    public func loadMarkdown(_ id: UUID) async throws -> (item: ReaderItem, text: String) {
        let opened = try await vault.markdown(of: id)
        if opened.item.keptOriginalID != nil, !items.contains(where: { $0.id == opened.item.keptOriginalID }) { await load() }
        return opened
    }

    /// Every reference library merged, as CSL JSON. An empty list when there's none or it won't open.
    public func referenceLibrary() async -> Data {
        (try? await vault.referenceLibrary()) ?? Data("[]".utf8)
    }

    // MARK: Links between docs

    /// Every doc's title, for the writing page to tell a link that leads somewhere from one that doesn't.
    public var docTitles: [String] {
        items.filter { $0.kind == .note && !$0.title.isEmpty }.map(\.title)
    }

    /// Opens the doc a wiki link names. False when there's no such doc, so the screen can offer to make it.
    public func followWikiLink(_ target: String, heading: String, from source: ReaderItem) -> Bool {
        guard let found = WikiLinks.resolve(target, in: items, near: source.folderID) else { return false }
        linkedHeading = heading.isEmpty ? nil : LinkedHeading(id: found.id, heading: heading)
        linkedItem = found.id
        return true
    }

    /// Makes the doc a link names, beside the doc the link is in, and opens it.
    public func createLinkedDoc(_ title: String, from source: ReaderItem) async {
        do {
            let created = try await vault.createNote(title: title, folder: source.folderID)
            await load()
            linkedItem = created.id
        } catch {
            notice = "The doc couldn't be created."
        }
    }

    public func backlinks(to id: UUID) async throws -> [WikiLinks.Backlink] {
        try await vault.backlinks(to: id)
    }

    /// A doc's Markdown for export. An older doc is converted in memory only, never saved, since an
    /// export shouldn't change anything.
    public func markdownForExport(_ id: UUID) async -> String? {
        guard let item = try? await vault.item(id), item.kind == .note, let data = try? await vault.body(of: id) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        if item.mime == MarkdownText.mime { return text }
        return MarkdownText.markdown(from: item.mime == ReadableText.markdownMime ? DocText(markdown: text) : DocText(plain: text))
    }

    /// The images a doc's figures point to, by the address each was written with. An image comes from a
    /// Reader file of that name (the doc's own folder first) or from the address itself; export never
    /// fetches one from the internet, and an address it can't find is left as its caption.
    public func exportImages(for document: ExportDocument, near folder: UUID?) async -> [String: ExportImage] {
        var found: [String: ExportImage] = [:]
        let files = items.filter { $0.kind == .file && ($0.mime ?? "").hasPrefix("image/") }
        func key(_ name: String) -> String {
            let lowered = name.lowercased()
            return (lowered as NSString).deletingPathExtension
        }
        for source in document.imageSources.prefix(200) {
            if let inline = ExportImage.inline(source) {
                found[source] = ExportImage(data: inline)
                continue
            }
            guard let name = ExportImage.filename(source).map(key), !name.isEmpty else { continue }
            let matches = files.filter { key($0.title) == name }
            guard let file = matches.first(where: { $0.folderID == folder }) ?? matches.max(by: { $0.updatedAt < $1.updatedAt }),
                  let data = try? await vault.body(of: file.id)
            else { continue }
            found[source] = ExportImage(data: data)
        }
        return found
    }

    // MARK: Versions

    public func versions(of id: UUID) async throws -> [DocVersion] {
        try await vault.versions(of: id)
    }

    /// Failing here costs only a version, so it doesn't interrupt the person.
    public func snapshot(_ id: UUID) async {
        _ = try? await vault.snapshot(id)
    }

    public func versionText(_ version: DocVersion, of id: UUID) async throws -> String {
        try await vault.versionText(version.id, of: id)
    }

    /// Returns false when the version couldn't be put back.
    public func restoreVersion(_ version: DocVersion, of id: UUID) async -> Bool {
        do {
            try await vault.restoreVersion(version.id, of: id)
            await load()
            await search()
            return true
        } catch {
            notice = "That version couldn't be restored."
            return false
        }
    }

    public func setWordTarget(_ target: Int?, of id: UUID) async -> Bool {
        do {
            try await vault.setWordTarget(target, of: id)
            await load()
            return true
        } catch {
            notice = "The word target wasn't saved."
            return false
        }
    }

    /// The converted doc looks right, so its kept original goes to Recently Deleted.
    public func confirmConversion(_ id: UUID) async -> Bool {
        do {
            try await vault.confirmConversion(id)
            await load()
            return true
        } catch {
            notice = "The original couldn't be moved to Recently Deleted."
            return false
        }
    }

    /// Returns false when the save failed, so the editor keeps the text for another try.
    @discardableResult
    public func saveNote(_ id: UUID, title: String, body: String) async -> Bool {
        do {
            try await vault.saveNote(id, title: title, body: body)
            await load()
            await search()
            return true
        } catch {
            notice = "Your latest changes weren't saved."
            return false
        }
    }

    /// For an open note. Returns the version now saved, or nil if the save failed. If the note changed
    /// elsewhere, what was typed is kept as a copy, and that copy opens so typing carries on there.
    public func saveMarkdown(_ id: UUID, title: String, text: String, basedOn: Date) async -> NoteSave? {
        await saveNote(id, title: title, body: text, mime: MarkdownText.mime, basedOn: basedOn)
    }

    public func saveNote(_ id: UUID, title: String, body: String, mime: String? = nil, basedOn: Date) async -> NoteSave? {
        do {
            let result = try await vault.saveNote(id, title: title, body: body, mime: mime, basedOn: basedOn)
            await load()
            await search()
            if case .keptAsCopy(let copy) = result {
                notice = "This note changed on another device. What you typed is kept as \(copy.displayTitle)."
                requestedItem = copy.id
            }
            return result
        } catch {
            notice = "Your latest changes weren't saved."
            return nil
        }
    }

    public func document(of id: UUID) async throws -> ReadableDocument {
        try await vault.document(of: id)
    }

    /// The file itself, decrypted into memory only, for a viewer that needs it whole, like an image.
    public func fileData(of id: UUID) async throws -> Data {
        try await vault.body(of: id)
    }

    /// The file, read a piece at a time as a viewer asks for it. Never written anywhere unsealed.
    public func file(of id: UUID) async throws -> ReaderFile {
        try await vault.file(of: id)
    }

    public func text(of id: UUID) async throws -> String {
        try await vault.text(of: id)
    }

    public func importFiles(_ urls: [URL], into folder: UUID? = nil) async {
        var failures: [String] = []
        for url in urls {
            do {
                try await importFile(url, folder: folder)
            } catch let error as ReaderError {
                failures.append("\(url.lastPathComponent): \(error.message)")
            } catch {
                failures.append("\(url.lastPathComponent): it couldn't be read.")
            }
        }
        if !failures.isEmpty { notice = failures.joined(separator: "\n") }
        await load()
    }

    /// Read and sealed a piece at a time, so a file of any size up to 5 GB never sits in memory whole.
    private func importFile(_ url: URL, folder: UUID?) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= ReaderVault.maxFileBytes else { throw ReaderError.tooLarge }
        // Refused now, rather than sealed here and then never able to sync. Unknown room doesn't stop it.
        if let storageLeft, let left = await storageLeft(), size > left { throw ReaderError.storageFull }
        let name = url.lastPathComponent
        let shows = size > ImportProgress.shownOver
        if shows { importing = ImportProgress(name: name, fraction: 0) }
        defer { if shows { importing = nil } }
        _ = try await vault.importFile(at: url, filename: name, folder: folder) { fraction in
            guard shows else { return }
            Task { @MainActor [weak self] in
                guard let self, self.importing?.name == name else { return }
                // Small steps would redraw the bar for nothing.
                if fraction - (self.importing?.fraction ?? 0) >= 0.01 || fraction >= 1 {
                    self.importing = ImportProgress(name: name, fraction: fraction)
                }
            }
        }
    }

    public func delete(_ item: ReaderItem) async {
        do {
            for id in try await vault.delete(item.id) {
                listen.remove(id)
                forgetPrepared(id)
            }
            await load()
        } catch {
            notice = "\(item.displayTitle) couldn't be deleted."
        }
    }

    public func startListening(to id: UUID) async {
        let opened = listen.open(id, title: title(of: id))
        if let track = await track(for: id) { listen.play(track, opened: opened) } else { listen.cancel(opened) }
    }

    public func addToQueue(_ id: UUID) async {
        guard listen.isActive else { return await startListening(to: id) }
        if let track = await track(for: id) { listen.enqueue(track) }
    }

    /// Reading from a place on the page: `script` is the text the page shows. If Listen is reading
    /// something else, or an older version of this, it starts over from there.
    public func listen(to id: UUID, from offset: Int, on script: ListenScript) async {
        if listen.current?.id == id, listen.current?.script.fingerprint == script.fingerprint {
            listen.jump(to: script.index(at: offset))
        } else {
            let opened = listen.open(id, title: title(of: id))
            if let track = await track(for: id, from: offset) { listen.play(track, opened: opened) } else { listen.cancel(opened) }
        }
    }

    /// Read headings changed, so what's playing is read again from where it is, the new way.
    public func readHeadingsChanged() async {
        // Paused, it carries on the old way until it's played again, rather than starting to speak.
        guard let current = listen.current, !listen.isPaused, current.script.sentences.indices.contains(listen.sentence) else { return }
        let offset = current.script.sentences[listen.sentence].offset
        guard let script = await readAlongScript(of: current.id), script.fingerprint != current.script.fingerprint,
              let track = ListenTrack(id: current.id, title: current.title, script: script, startOffset: offset)
        else { return }
        listen.play(track)
    }

    /// What Listen reads in an item, for following along on its page. It's the same script Listen speaks,
    /// so the highlight and the voice can't drift apart.
    public func readAlongScript(of id: UUID) async -> ListenScript? {
        try? await script(for: id).get()
    }

    /// For an item that's open, where Listen is likely next: the voice loads, and the text is read and
    /// split now rather than after the button is pressed. Only the latest item is kept.
    public func prepareListening(to id: UUID) async {
        listen.warmUp()
        _ = await script(for: id)
    }

    private func title(of id: UUID) -> String {
        (library.items.first { $0.id == id } ?? library.lastOpened.first { $0.id == id } ?? journalItem(id))?.displayTitle ?? ""
    }

    private func track(for id: UUID, from offset: Int? = nil) async -> ListenTrack? {
        do {
            let item = try await vault.item(id)
            guard let script = try await script(for: id).get(),
                  let track = ListenTrack(id: id, title: item.displayTitle, script: script, startOffset: offset ?? item.listenPosition)
            else {
                notice = "There's nothing to read aloud here yet."
                return nil
            }
            return track
        } catch let error as ReaderError {
            notice = error.message
        } catch {
            notice = "This item couldn't be opened."
        }
        return nil
    }

    /// Splitting a long book takes about a second on a phone, so it happens away from the main thread,
    /// and once per version of the text. Nil when the item has nothing to split.
    private func script(for id: UUID) async -> Result<ListenScript?, any Error> {
        let readHeadings = UserDefaults.standard.bool(forKey: ListenSkips.readHeadingsKey)
        if prepared?.id != id || prepared?.readHeadings != readHeadings {
            let vault = self.vault
            prepared = (id, readHeadings, Task {
                do {
                    let text = try await vault.text(of: id)
                    let mime = try await vault.item(id).mime
                    let file = try await vault.file(of: id)
                    // Headings and page furniture are found from the file, and left out of what's read.
                    let script = await Task.detached(priority: .userInitiated) {
                        ListenScript(text: text, skipping: ListenSkips.ranges(text: text, file: file, mime: mime, readHeadings: readHeadings))
                    }.value
                    return .success((text, script))
                } catch {
                    return .failure(error)
                }
            })
        }
        guard let prepared else { return .success(nil) }
        let result = await prepared.split.value
        // An edit since, or a failure, means the next ask starts again.
        do {
            let (split, made) = try result.get()
            guard let current = try? await vault.text(of: id), current == split else {
                if self.prepared?.split == prepared.split { self.prepared = nil }
                return await script(for: id)
            }
            return .success(made)
        } catch {
            if self.prepared?.split == prepared.split { self.prepared = nil }
            return .failure(error)
        }
    }

    /// Drops a prepared script, so a deleted item's text doesn't stay in memory.
    private func forgetPrepared(_ id: UUID? = nil) {
        if id == nil || prepared?.id == id { prepared = nil }
    }
}


/// A heading a wiki link named, in the doc it leads to.
public struct LinkedHeading: Equatable, Sendable {
    public let id: UUID
    public let heading: String
}

// MARK: Reading places

extension ReaderModel {
    /// Where to open an item: where the person stopped, or Listen's place when Read along is on and Listen
    /// got further.
    public func opening(of item: ReaderItem) async -> ReadingPlaces.Opening? {
        let readAlong = UserDefaults.standard.bool(forKey: ReaderItemView.readAlongKey)
        let listen = item.listenPosition > 0 ? item.listenPosition : nil
        guard let places else { return readAlong ? listen.map(ReadingPlaces.Opening.listen) : nil }
        return await places.all().opening(item.id, listenOffset: listen, readAlong: readAlong, readingOffset: nil)
    }

    /// Keeps where the person is. `listen` is the same place in Listen's text, when it's known.
    public func remember(_ spot: ReadingPlace.Spot, listen: Int? = nil, for id: UUID) {
        guard let places else { return }
        Task { try? await places.remember(spot, listen: listen, for: id) }
    }

    /// Sends held places into the synced record, as the app goes to the background.
    public func publishPlaces() async {
        try? await places?.publish()
    }

    private func forgetPlaces(_ ids: Set<UUID>) async {
        guard let places, !ids.isEmpty else { return }
        try? await places.forget(ids)
    }
}

/// A big file on its way into the Reader.
public struct ImportProgress: Equatable, Sendable {
    /// Smaller files are done before a bar would be seen.
    public static let shownOver = 50 * 1024 * 1024

    public let name: String
    /// From 0 to 1.
    public let fraction: Double
}
