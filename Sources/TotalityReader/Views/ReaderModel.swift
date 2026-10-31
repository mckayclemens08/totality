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

    public private(set) var phase = Phase.loading
    public private(set) var items: [ReaderItem] = []
    public private(set) var unreadable = 0
    public private(set) var hits: [ReaderSearchHit] = []
    public var query = ""
    /// An item another module asked to open. The home screen takes it from here.
    public var requestedItem: UUID?
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

    public var sections: [(title: String, items: [ReaderItem])] {
        let groups = Dictionary(grouping: items) { $0.collection ?? "" }
        return groups.keys.sorted().map { (title: $0, items: groups[$0] ?? []) }
    }

    /// Stops anything that could write, for when every blob is about to be rewritten under a new key.
    public func stopForKeyChange() async {
        listen.stop()
        await Task.yield()
        _ = try? await vault.list()
    }

    public func load() async {
        do {
            let listing = try await vault.list()
            items = listing.items
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
        } catch {
            notice = "Search didn't finish. Try again."
        }
    }

    public func newNote() async -> ReaderItem? {
        do {
            let item = try await vault.createNote()
            await load()
            return item
        } catch {
            notice = "The note couldn't be created."
            return nil
        }
    }

    public func currentItem(_ id: UUID) async throws -> ReaderItem {
        try await vault.item(id)
    }

    public func loadNote(_ id: UUID) async throws -> String {
        String(decoding: try await vault.body(of: id), as: UTF8.self)
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

    public func text(of id: UUID) async throws -> String {
        try await vault.text(of: id)
    }

    public func importFiles(_ urls: [URL], collection: String? = nil) async {
        var failures: [String] = []
        for url in urls {
            do {
                try await importFile(url, collection: collection)
            } catch let error as ReaderError {
                failures.append("\(url.lastPathComponent): \(error.message)")
            } catch {
                failures.append("\(url.lastPathComponent): it couldn't be read.")
            }
        }
        if !failures.isEmpty { notice = failures.joined(separator: "\n") }
        await load()
    }

    private func importFile(_ url: URL, collection: String?) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= ReaderVault.maxImportBytes else { throw ReaderError.tooLarge }
        _ = try await vault.importFile(Data(contentsOf: url), filename: url.lastPathComponent, collection: collection)
    }

    public func delete(_ item: ReaderItem) async {
        listen.remove(item.id)
        do {
            try await vault.delete(item.id)
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
