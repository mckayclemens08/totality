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
    /// True once this device syncs, which decides what the screen can truthfully say about recovery.
    public var isSynced = false
    /// A problem to show the person, cleared when they dismiss it.
    public var notice: String?

    public let listen: ListenController
    private let vault: ReaderVault

    public init(vault: ReaderVault, listen: ListenController) {
        self.vault = vault
        self.listen = listen
        listen.onPosition = { [vault] id, offset in
            Task { try? await vault.setListenPosition(offset, of: id) }
        }
    }

    public var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var items: [ReaderItem] {
        library.items
    }

    /// For the home tile: what's playing, then what was opened last. Nil until the library opens, so a
    /// tile can't claim it's empty while it's loading.
    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        guard !items.isEmpty else { return ModuleGlance(lines: ["Nothing saved yet"], isQuiet: true) }
        let playing = listen.current
        let recent = library.lastOpened.filter { $0.id != playing?.id }.map(\.displayTitle)
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        return ModuleGlance(lines: (playing.map { ["Listening to \($0.title)"] } ?? []) + recent.prefix(Self.glanceTitles) + [count])
    }

    /// What the home tile puts first: what's playing, or else what was opened last.
    public var frontOfShelf: ReaderItem? {
        let playing = listen.current?.id
        return items.first { $0.id == playing } ?? library.lastOpened.first
    }

    /// Stops anything that could write, for when every blob is about to be rewritten under a new key.
    public func stopForKeyChange() async {
        listen.stop()
        await vault.close()
    }

    public func load() async {
        do {
            try? await vault.adoptCollections()
            // Sync does this too, but "30 days" has to hold on a device that's offline.
            try? await vault.emptyOldTrash()
            let listing = try await vault.list()
            library = ReaderLibrary(items: listing.items, folders: listing.folders, opened: listing.opened)
            trash = try await vault.trashed()
            unreadable = listing.unreadable
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
    }

    public func emptyTrash() async {
        await change("Recently Deleted couldn't be emptied.") { try await $0.emptyTrash() }
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

    public func loadDoc(_ id: UUID) async throws -> DocText {
        try await vault.doc(id)
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
    public func saveDoc(_ id: UUID, title: String, doc: DocText, basedOn: Date) async -> NoteSave? {
        await saveNote(id, title: title, body: doc.markdown, mime: ReadableText.markdownMime, basedOn: basedOn)
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

    /// The file itself, decrypted into memory only, for showing PDF pages.
    public func fileData(of id: UUID) async throws -> Data {
        try await vault.body(of: id)
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

    private func importFile(_ url: URL, folder: UUID?) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= ReaderVault.maxImportBytes else { throw ReaderError.tooLarge }
        _ = try await vault.importFile(Data(contentsOf: url), filename: url.lastPathComponent, folder: folder)
    }

    public func delete(_ item: ReaderItem) async {
        do {
            for id in try await vault.delete(item.id) { listen.remove(id) }
            await load()
        } catch {
            notice = "\(item.displayTitle) couldn't be deleted."
        }
    }

    public func startListening(to id: UUID) async {
        if let track = await track(for: id) { listen.play(track) }
    }

    public func addToQueue(_ id: UUID) async {
        if let track = await track(for: id) { listen.enqueue(track) }
    }

    private func track(for id: UUID) async -> ListenTrack? {
        do {
            let item = try await vault.item(id)
            let text = try await vault.text(of: id)
            guard let track = ListenTrack(id: id, title: item.displayTitle, text: text, startOffset: item.listenPosition) else {
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
}
