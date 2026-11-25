import AuthenticationServices
import Foundation
import Observation
import TotalityCore

/// What the Reader's Google Drive screens show. All the work happens in `GoogleDrive`.
@MainActor
@Observable
public final class DriveModel {
    /// Shows Google's page and hands back where it returned to. The view supplies it, because only a view
    /// can present Google's sign-in sheet.
    public typealias SignIn = @MainActor (_ page: URL, _ callbackScheme: String) async throws -> URL

    /// The honest label for anything from Drive (rule 5): Google holds it, and can read it.
    public nonisolated static let label = "Stored in Google Drive, not end-to-end encrypted"
    public nonisolated static let explanation =
        "Linked folders stay in Google Drive. Google can read them, so they aren't end-to-end encrypted. "
        + "Totality asks Google for your whole Drive but shows only the folders you link. This device talks to Google "
        + "directly, and Totality's server never sees your files or your Google sign-in. Which folders you linked "
        + "syncs to your other devices end-to-end encrypted, so the server can't read their names."

    public private(set) var accounts: [DriveAccount] = []
    /// The Google sign-ins on this device couldn't be read just now, which is not the same as none. The
    /// screens say so and offer to try again, never Connect.
    public private(set) var signInUnreadable = false
    public nonisolated static let signInUnreadableMessage = "Couldn't read your Google sign-in, try again."
    public private(set) var links: [DriveLink] = []
    /// Folders linked on another device, for a Google account not connected on this one.
    public private(set) var elsewhere: [DriveLink] = []
    /// True while Google's page is open or its answer is being checked.
    public private(set) var isConnecting = false
    /// A problem to show on the Drive screens, cleared when it's dismissed or the next try starts.
    public var problem: String?
    /// What's shown of each folder, by `"account/folderID"`: kept first, then fresh from Google.
    public private(set) var listings: [String: DriveListing] = [:]
    /// Folders that couldn't be read last time, by `"account/folderID"`.
    public private(set) var folderProblems: [String: DriveProblem] = [:]
    /// Accounts with linked folders that no longer allow Drive.
    public private(set) var needsAllowing: Set<String> = []
    /// Linked folders and the files opened from them, newest first, for the Reader's home tile.
    public private(set) var recent: [DriveRecent] = []

    let drive: GoogleDrive
    /// Where an opened file is held, so the Reader's viewers and Listen can read it.
    private let vault: ReaderVault?
    private let settings: UserDefaults

    /// Holds only a number, and stays with the device.
    static let cacheLimitKey = "reader.drive.cacheLimit"

    public init(drive: GoogleDrive, vault: ReaderVault? = nil, settings: UserDefaults = .standard) {
        self.drive = drive
        self.vault = vault
        self.settings = settings
        let stored = settings.integer(forKey: Self.cacheLimitKey)
        cacheLimit = DriveCacheLimit.choices.contains(stored) ? stored : DriveCacheLimit.standard
    }

    // MARK: Opening files

    /// How much opened files may take on this device.
    public private(set) var cacheLimit: Int
    /// How much they take now, once it's been read.
    public private(set) var cachedBytes: Int?

    public func setCacheLimit(_ limit: Int) async {
        guard DriveCacheLimit.choices.contains(limit) else { return }
        cacheLimit = limit
        settings.set(limit, forKey: Self.cacheLimitKey)
        try? await drive.trimCache(to: limit)
        await readCacheSize()
    }

    public func readCacheSize() async {
        cachedBytes = try? await drive.cachedBytes()
    }

    public func clearCache() async {
        do {
            try await drive.clearCache()
        } catch {
            problem = "Downloaded files couldn't be cleared."
        }
        await readCacheSize()
    }

    /// The ID a Drive file opens under in the Reader. The same file gets the same one, so Listen picks up
    /// where it was in this run. It's never stored.
    nonisolated static func readerID(account: String, fileID: String) -> UUID {
        UUID(derivedFrom: "totality.reader.drive.file.\(GoogleDrive.key(account, fileID))")
    }

    /// Opens a file, from what's kept or from Google, and hands it to the Reader as an item held in
    /// memory only. Text and Markdown can then be edited and saved back; everything else is read-only.
    public func openFile(_ entry: DriveEntry, in folderID: String, account: String) async throws -> (item: ReaderItem, file: DriveOpenedFile) {
        guard vault != nil else { throw ReaderError.notFound }
        let file = try await drive.file(entry.id, in: folderID, account: account, limit: cacheLimit)
        let item = try await hold(file)
        await readCacheSize()
        await loadRecent()
        return (item, file)
    }

    public var isAvailable: Bool { drive.isAvailable }

    @ObservationIgnored private var swept = false

    public func load() async {
        if !swept {
            // Once per run: anything another key left in the cache folder goes.
            swept = (try? await drive.sweepCache()) != nil
        }
        do {
            accounts = try await drive.connections()
            signInUnreadable = false
        } catch {
            // What was shown stays. Nothing here offers Connect for an account that may well be connected.
            signInUnreadable = true
        }
        do {
            if signInUnreadable {
                // Which accounts are here isn't known, so every folder shows, each saying "try again".
                links = try await drive.allLinks()
                elsewhere = []
            } else {
                links = try await drive.links()
                let here = Set(links.map(\.id))
                elsewhere = try await drive.allLinks().filter { !here.contains($0.id) }
            }
        } catch {
            problem = "Your linked Drive folders couldn't be read on this device."
        }
        await loadRecent()
    }

    /// Sends what was opened lately into the synced record, as the app goes to the background.
    public func publishOpened() async {
        try? await drive.publishHeld()
    }

    /// True for a Google account that isn't connected on this device. Its folders show "Connect to see".
    public func needsConnecting(_ account: String) -> Bool {
        !signInUnreadable && !accounts.contains { $0.address == account }
    }

    /// Reads what the home tile shows. A problem reads as nothing, so the tile never shows stale entries.
    public func loadRecent() async {
        recent = (try? await drive.recent()) ?? []
    }

    /// The ID the home tile and Listen know a recent entry by. A file's is the one it opens under.
    public nonisolated static func shelfID(_ recent: DriveRecent) -> UUID {
        recent.isFolder
            ? UUID(derivedFrom: "totality.reader.drive.folder.\(recent.key)")
            : readerID(account: recent.account, fileID: recent.id)
    }

    /// Where a tile entry opens: a linked folder, or a file where its folder lists it now.
    public enum ShelfTarget: Equatable {
        case folder(account: String, folderID: String, name: String)
        case file(account: String, folderID: String, entry: DriveEntry)
    }

    public func target(of recent: DriveRecent) async -> ShelfTarget? {
        if recent.isFolder {
            // Linked on another device too, so a tap can offer to connect.
            let links = (try? await drive.allLinks()) ?? []
            guard let link = links.first(where: { $0.account == recent.account && $0.folderID == recent.id }) else { return nil }
            return .folder(account: link.account, folderID: link.folderID, name: link.name)
        }
        var found = try? await drive.whereIs(recent.id, account: recent.account)
        if found == nil {
            // No listing here shows it yet: read the linked folders once, then look again.
            _ = await refreshAll(force: true)
            found = try? await drive.whereIs(recent.id, account: recent.account)
        }
        guard let found else { return nil }
        return .file(account: recent.account, folderID: found.folderID, entry: found.entry)
    }

    public func links(for account: String) -> [DriveLink] {
        links.filter { $0.account == account }
    }

    public func isLinked(_ folder: DriveEntry, account: String) -> Bool {
        links.contains { $0.account == account && $0.folderID == folder.id }
    }

    // MARK: Connecting

    /// Allows Drive on an account, or connects a new one when `account` is nil. Returns the account
    /// that now allows Drive, or nil if it didn't happen. An account that already allows it needs nothing.
    public func connect(_ account: String?, signIn: SignIn) async -> String? {
        if let account, accounts.first(where: { $0.address == account })?.allowsDrive == true { return account }
        guard let authorization = await drive.authorization(for: account) else {
            problem = DriveProblem.notSetUp.message
            return nil
        }
        isConnecting = true
        problem = nil
        defer { isConnecting = false }
        do {
            let callback = try await signIn(authorization.url, authorization.callbackScheme)
            let address = try await drive.finish(authorization, callback: callback)
            await load()
            return address
        } catch is CancellationError {
            return nil
        } catch let error as DriveProblem {
            problem = error == .notAllowed
                ? "Drive wasn't allowed on Google's page, so Totality can't see its folders. Try again and leave Drive ticked."
                : error.message
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The person closed Google's page, which isn't a problem to show.
            return nil
        } catch {
            problem = DriveProblem.from(error).message
        }
        await load()
        return nil
    }

    // MARK: Browsing

    public func listing(_ folderID: String, account: String) -> DriveListing? {
        listings[GoogleDrive.key(account, folderID)]
    }

    public func problem(_ folderID: String, account: String) -> DriveProblem? {
        folderProblems[GoogleDrive.key(account, folderID)]
    }

    /// What was kept shows at once, then Google is asked.
    public func open(_ folderID: String, account: String) async {
        let key = GoogleDrive.key(account, folderID)
        if (try? await drive.noteOpenedFolder(folderID, account: account)) != nil { await loadRecent() }
        if listings[key] == nil, let kept = try? await drive.kept(folderID, account: account) { listings[key] = kept }
        await refresh(folderID, account: account)
    }

    public func refresh(_ folderID: String, account: String) async {
        let key = GoogleDrive.key(account, folderID)
        do {
            listings[key] = try await drive.refresh(folderID, account: account)
            folderProblems[key] = nil
        } catch is CancellationError {
        } catch {
            folderProblems[key] = DriveProblem.from(error)
        }
    }

    /// How often the quiet refresh asks Google, which the Reader's refresher runs every minute.
    static let quietInterval: TimeInterval = 5 * 60
    @ObservationIgnored private var running: Task<RefreshOutcome, Never>?
    @ObservationIgnored private var lastRefreshed: Date?

    /// The Reader's quiet refresh and pull-to-refresh, as steps of its `Refresher`. A pull always asks
    /// Google; the quiet one only every few minutes, so Drive isn't asked every minute.
    public func attach(to refresher: Refresher) {
        refresher.add("google drive", limit: .seconds(60), onlyWhenPulled: true) { [weak self] in
            await self?.refreshAll(force: true) ?? .done
        }
        refresher.add("google drive quietly", limit: .seconds(60)) { [weak self] in
            await self?.refreshAll(force: false) ?? .done
        }
    }

    /// A run already going is joined, not repeated.
    func refreshAll(force: Bool) async -> RefreshOutcome {
        if let running { return await running.value }
        if !force, let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < Self.quietInterval { return .done }
        let task = Task { await self.readAll(onlyChanged: !force) }
        running = task
        let outcome = await task.value
        running = nil
        lastRefreshed = Date()
        return outcome
    }

    /// Goes up for a file whenever a newer version of it was downloaded, by `"account/fileID"`, so a screen
    /// showing it opens the new one.
    public private(set) var fileUpdates: [String: Int] = [:]

    /// A pull reads every folder. The quiet refresh asks Drive what changed and reads only that, then
    /// downloads again any kept file that changed, so it's current before it's opened.
    private func readAll(onlyChanged: Bool) async -> RefreshOutcome {
        let result = await drive.refreshAll(onlyChanged: onlyChanged)
        let updated = await drive.refreshKeptFiles(limit: cacheLimit)
        for key in updated { fileUpdates[key, default: 0] += 1 }
        if !updated.isEmpty { await readCacheSize() }
        await load()
        if result.signInUnreadable { return .failed(Self.signInUnreadableMessage) }
        folderProblems = result.problems
        needsAllowing = result.needsAllowing
        var fresh: [String: DriveListing] = [:]
        for key in listings.keys {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let kept = try? await drive.kept(parts[1], account: parts[0]) { fresh[key] = kept }
        }
        listings = fresh
        let problems = Set(result.problems.values)
        if problems.isEmpty { return .done }
        if problems == [.offline] { return .offline }
        // A folder gone from Drive shows on its own row, and a passing problem only once it lasts.
        let lasting = problems.subtracting([.notFound]).first { !$0.isPassing } ?? problems.first { $0 != .notFound }
        return lasting.map { .failed($0.message) } ?? .done
    }

    // MARK: Choosing

    public func folders(in place: DrivePlace, account: String) async throws -> [DriveEntry] {
        try await drive.folders(in: place, account: account)
    }

    /// Links or unlinks a folder the chooser shows.
    public func setLinked(_ isLinked: Bool, folder: DriveEntry, account: String) async {
        do {
            if isLinked {
                try await drive.link(folder, account: account)
            } else if let link = links.first(where: { $0.account == account && $0.folderID == folder.id }) {
                try await drive.unlink(link)
                await forgetOpened()
            }
        } catch {
            problem = isLinked ? "\(folder.name) couldn't be linked." : "\(folder.name) couldn't be unlinked."
        }
        await load()
    }

    public func unlink(_ link: DriveLink) async {
        do {
            try await drive.unlink(link)
            await forgetOpened()
        } catch {
            problem = "\(link.name) couldn't be unlinked."
        }
        await load()
    }

    /// Who's signed in, as the app last said. Nil inside means signed out.
    @ObservationIgnored private var owner: String??

    /// Any change of who's here, signing out included, drops every Drive file held open and what's shown
    /// of folders, so nothing opened by one person can be read after them.
    public func use(owner: String?) async {
        defer { self.owner = .some(owner) }
        guard let before = self.owner, before != owner else { return }
        await forgetOpened()
        if owner != nil { await loadRecent() }
    }

    /// Goes up whenever opened files are dropped, so a screen showing one lets it go too.
    public private(set) var openedGeneration = 0

    func forgetOpened() async {
        openedGeneration += 1
        await vault?.releaseHeld()
        listings = [:]
        folderProblems = [:]
        recent = []
    }

    // MARK: Editing and importing (step 4)

    public enum SaveOutcome: Equatable {
        case saved(DriveOpenedFile)
        /// Drive's copy changed since it was opened. Nothing was sent.
        case changedInDrive
        case failed(String)
    }

    /// Saves text over the file in Drive, unless Drive's copy changed since it was opened. `overwrite` is
    /// only for the person's "Use mine".
    public func save(_ text: String, over file: DriveOpenedFile, overwrite: Bool = false) async -> SaveOutcome {
        do {
            switch try await drive.save(text, over: file, overwrite: overwrite, limit: cacheLimit) {
            case .changedInDrive:
                return .changedInDrive
            case .saved(let saved):
                try await hold(saved)
                await readCacheSize()
                return .saved(saved)
            }
        } catch {
            return .failed("This wasn't saved to Google Drive. \(DriveProblem.from(error).message)")
        }
    }

    /// "Keep both": the text goes into a new file in the same folder, and the original stays as Drive has it.
    public func saveCopy(_ text: String, of file: DriveOpenedFile) async -> String? {
        do {
            let created = try await drive.saveCopy(text, of: file)
            listings[GoogleDrive.key(file.account, file.folderID)] = try? await drive.kept(file.folderID, account: file.account)
            return created.name
        } catch {
            problem = "Your copy wasn't saved to Google Drive. \(DriveProblem.from(error).message)"
            return nil
        }
    }

    /// Hands a file the Reader opened to the vault again, after it changed.
    @discardableResult
    func hold(_ file: DriveOpenedFile) async throws -> ReaderItem {
        guard let vault else { throw ReaderError.notFound }
        let item = ReaderItem(
            id: Self.readerID(account: file.account, fileID: file.entry.id), kind: .file, title: file.entry.name, collection: nil,
            mime: file.mime, byteCount: file.file.count, createdAt: file.modifiedAt ?? Date(),
            updatedAt: file.modifiedAt ?? Date(), listenPosition: 0
        )
        try await vault.hold(item, file: file.file)
        return item
    }

    /// Makes a Totality copy, which uses Totality storage. A Google Doc, a Word file, or Markdown becomes
    /// a doc to write in. Anything else becomes a sealed file, like any import.
    public func importToReader(_ file: DriveOpenedFile, into folder: UUID? = nil) async throws -> ReaderItem {
        guard let vault else { throw ReaderError.notFound }
        let title = Self.title(of: file.entry.name)
        if let markdown = Self.markdown(of: file) {
            let note = try await vault.createNote(title: title, folder: folder)
            return try await vault.saveNote(note.id, title: title, body: markdown, mime: MarkdownText.mime)
        }
        guard file.file.isPieces else { return try await vault.importFile(file.data, filename: Self.filename(for: file), folder: folder) }
        return try await vault.importFile(file.file, filename: Self.filename(for: file), folder: folder)
    }

    /// The name without a document extension, so "Essay.md" becomes "Essay" but "Report v1.2" stays.
    nonisolated static func title(of name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let base = (name as NSString).deletingPathExtension
        return ["md", "markdown", "txt", "docx"].contains(ext) && !base.isEmpty ? base : name
    }

    /// The Markdown a doc is made from, or nil for a file that's imported as it is.
    static func markdown(of file: DriveOpenedFile) -> String? {
        if file.mime == MarkdownText.mime { return String(decoding: file.data, as: UTF8.self) }
        if file.entry.mime == ReadableText.wordMime, let document = try? ReadableText.document(file.data, mime: ReadableText.wordMime) {
            return markdown(from: document)
        }
        return nil
    }

    /// Word's headings and paragraphs, as Markdown. Layout Word keeps beyond that doesn't come across.
    static func markdown(from document: ReadableDocument) -> String {
        document.sections.flatMap(\.blocks).compactMap { block in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return block.isHeading ? "## " + MarkdownText.escaped(text) : MarkdownText.escaped(text)
        }.joined(separator: "\n\n")
    }

    /// The name the vault reads the kind of file from, so a Sheet exported as PDF imports as a PDF.
    static func filename(for file: DriveOpenedFile) -> String {
        let name = file.entry.name
        if file.mime == "application/pdf", !name.lowercased().hasSuffix(".pdf") { return name + ".pdf" }
        return name
    }

    // MARK: Disconnecting

    public func alsoEnds(_ account: String) async -> Set<GoogleUse> {
        await drive.alsoEnds(account)
    }

    /// Takes Totality's access back at Google for this account, everywhere in Totality, and removes its
    /// linked folders and downloaded files here. Nothing in Google Drive changes.
    public func disconnect(_ account: String) async {
        do {
            try await drive.disconnect(account)
        } catch {
            problem = "\(account) couldn't be fully removed from this device. Try again."
        }
        await forgetOpened()
        await load()
        await readCacheSize()
    }

    /// For a key move or a change of account.
    public func close() async {
        await drive.close()
        links = []
        elsewhere = []
        accounts = []
        listings = [:]
        folderProblems = [:]
        recent = []
    }
}
