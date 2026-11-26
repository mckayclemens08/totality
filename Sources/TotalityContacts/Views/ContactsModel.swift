import Foundation
import Observation
import TotalityCore

/// Contacts' state: the sealed cards, opened on this device, and the work of importing from and syncing
/// with iPhone Contacts. Opening reads from the sealed store, so it's quick (issue 205, section 7).
@MainActor
@Observable
public final class ContactsModel {
    public enum Phase: Equatable {
        case loading, ready, failed
    }

    /// How an import is going: sealed so far, out of how many.
    public struct Progress: Equatable {
        public var done: Int
        public var total: Int
    }

    static let twoWayKey = "contacts.twoWaySync"
    /// The most addresses one message takes, as Mail agreed in issue 37.
    public static let mailLimit = 10

    public private(set) var phase = Phase.loading
    /// Every card that opened, Recently Deleted included.
    public private(set) var cards: [ContactCard] = []
    /// Cards that wouldn't open on this device. They're kept, never dropped.
    public private(set) var unreadable = 0
    public private(set) var progress: Progress?
    public private(set) var deviceAccess: DeviceAccess
    /// A short line about what just happened or went wrong, shown once.
    public var notice: String?
    /// The label chosen above the list, which is also the group Mail all writes to.
    public var label: String?
    /// A card asked for from search, a ref or the Calendar, opened next time the screen shows.
    public var requestedCard: UUID?
    /// Edits here also change iPhone Contacts, for cards copied from it.
    public var twoWaySync: Bool {
        didSet {
            defaults.set(twoWaySync, forKey: Self.twoWayKey)
            if twoWaySync, !oldValue { Task { await syncWithDevice() } }
        }
    }
    public let refresher = Refresher()

    /// The app sets these. Each hands the person over to another module; none sends anything by itself.
    @ObservationIgnored public var onMessage: ((String) -> Void)?
    @ObservationIgnored public var onMail: (([String]) -> Void)?
    @ObservationIgnored public var onProfile: ((String) -> Void)?
    @ObservationIgnored public var taskMaker: (any TaskMaker)?
    /// Public profiles, to check a handle exists before linking it and to show their photo.
    @ObservationIgnored public var profiles: (any ProfileDirectory)?

    @ObservationIgnored private let vault: ContactVault?
    @ObservationIgnored public let directory: ContactsDirectory
    @ObservationIgnored public let device: (any DeviceContacts)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored public var calendar: Calendar

    public init(
        vault: ContactVault?, directory: ContactsDirectory = ContactsDirectory(), device: (any DeviceContacts)?,
        defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.vault = vault
        self.directory = directory
        self.device = device
        self.defaults = defaults
        self.calendar = calendar
        clock = now
        deviceAccess = device?.access ?? .denied
        twoWaySync = defaults.bool(forKey: Self.twoWayKey)
        refresher.add("contacts") { [weak self] in
            guard let self else { return .done }
            await self.load()
            if self.twoWaySync { await self.syncWithDevice() }
            return self.phase == .failed ? .failed("Your contacts couldn't be read on this device.") : .done
        }
    }

    public var now: Date { clock() }

    // MARK: What shows

    /// The cards not in Recently Deleted, in order of family name.
    public var live: [ContactCard] {
        cards.filter { !$0.isDeleted }.sorted { $0.sortKey < $1.sortKey }
    }

    public var favourites: [ContactCard] {
        cards.filter { !$0.isDeleted && $0.isFavourite }.sorted { ($0.favouriteOrder, $0.sortKey) < ($1.favouriteOrder, $1.sortKey) }
    }

    /// Recently Deleted, newest first.
    public var deleted: [ContactCard] {
        cards.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Every label in use, in order.
    public var labels: [String] {
        var seen = Set<String>()
        return live.flatMap(\.labels).filter { seen.insert($0.lowercased()).inserted }.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    /// The list under the chosen label, if one is chosen.
    public var shown: [ContactCard] {
        guard let label else { return live }
        return live.filter { $0.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
    }

    public var isEmpty: Bool { live.isEmpty && unreadable == 0 }

    public var upcoming: [Birthdays.Upcoming] {
        Birthdays.upcoming(cards, from: now, in: calendar)
    }

    public func upcoming(for card: ContactCard) -> Birthdays.Upcoming? {
        upcoming.first { $0.card.id == card.id }
    }

    public func card(_ id: UUID) -> ContactCard? {
        cards.first { $0.id == id }
    }

    /// Everyone in the chosen label who has an address, for Mail all.
    public var groupAddresses: [String] {
        var seen = Set<String>()
        return shown.compactMap { $0.emailAddresses.first ?? $0.totalityAddress }.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The days left before a deleted card goes for good.
    public func daysLeft(_ card: ContactCard) -> Int {
        guard let deletedAt = card.deletedAt else { return 30 }
        let gone = deletedAt.addingTimeInterval(ContactVault.trashLifetime)
        return max(0, Int(ceil(gone.timeIntervalSince(now) / 86_400)))
    }

    /// What the home tile says when it's a glance.
    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        if live.isEmpty { return ModuleGlance(lines: ["No contacts yet"], isQuiet: true) }
        var lines: [String] = []
        if let next = upcoming.first { lines.append(Birthdays.headline(next, in: calendar)) }
        lines += favourites.prefix(3).map(\.shownName)
        if lines.isEmpty { lines.append("\(live.count) contacts") }
        return ModuleGlance(lines: lines)
    }

    // MARK: Opening

    public func load() async {
        guard let vault else {
            phase = .failed
            return
        }
        do {
            let listing = try await vault.everything()
            cards = listing.cards
            unreadable = listing.unreadable
            phase = .ready
            directory.update(cards)
            await purgeExpired()
        } catch {
            phase = .failed
        }
        deviceAccess = device?.access ?? .denied
    }

    /// Refuses further changes and forgets what's in memory, so nothing is saved under the old key.
    public func stopForKeyChange() async {
        await vault?.close()
        directory.clear()
        cards = []
    }

    /// Cards that sat in Recently Deleted for 30 days go for good, here and at the next sync everywhere.
    private func purgeExpired() async {
        guard let vault else { return }
        let expired = cards.filter { card in
            card.deletedAt.map { now.timeIntervalSince($0) > ContactVault.trashLifetime } ?? false
        }
        guard !expired.isEmpty else { return }
        for card in expired { try? await vault.delete(card.id) }
        cards.removeAll { card in expired.contains { $0.id == card.id } }
    }

    // MARK: Changing

    /// Saves a card made or edited here. With two-way sync on, a card copied from the iPhone is written
    /// back to iPhone Contacts too.
    @discardableResult
    public func save(_ edited: ContactCard, over original: ContactCard?) async -> ContactCard? {
        guard let vault else { return nil }
        var card = edited.tidied()
        card.updatedAt = now
        do {
            let saved = try await vault.save(card, over: original)
            put(saved)
            if twoWaySync, saved.origin != nil { await writeBack(saved) }
            return saved
        } catch {
            notice = "That card couldn't be saved. Try again."
            return nil
        }
    }

    private func put(_ card: ContactCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card } else { cards.append(card) }
        directory.update(cards)
    }

    public func toggleFavourite(_ card: ContactCard) async {
        var changed = card
        changed.isFavourite.toggle()
        if changed.isFavourite { changed.favouriteOrder = (favourites.map(\.favouriteOrder).max() ?? 0) + 1 }
        await save(changed, over: card)
    }

    /// Moves a card to Recently Deleted. It syncs, so it leaves every device together.
    public func delete(_ card: ContactCard) async {
        var changed = card
        changed.deletedAt = now
        changed.isFavourite = false
        if await save(changed, over: card) != nil { notice = "\(card.shownName) is in Recently Deleted for 30 days." }
    }

    public func restore(_ card: ContactCard) async {
        var changed = card
        changed.deletedAt = nil
        await save(changed, over: card)
    }

    /// Deletes for good: one card, or all of Recently Deleted. The screen asks first.
    public func deleteForever(_ ids: [UUID]) async {
        guard let vault else { return }
        for id in ids {
            do {
                try await vault.delete(id)
                cards.removeAll { $0.id == id }
            } catch {
                notice = "Some cards couldn't be deleted. Try again."
            }
        }
        directory.update(cards)
    }

    /// Folds `other` into `keep`. The other card goes to Recently Deleted, so a wrong merge can be undone.
    @discardableResult
    public func merge(keep: ContactCard, other: ContactCard) async -> ContactCard? {
        let merged = ContactMerge.merge(keep: keep, other: other, at: now)
        guard let saved = await save(merged, over: keep) else { return nil }
        var gone = other
        gone.deletedAt = now
        gone.isFavourite = false
        await save(gone, over: other)
        notice = "Merged. The other card is in Recently Deleted."
        return saved
    }

    // MARK: Links to @usernames

    public enum LinkResult: Equatable {
        case linked(ContactCard)
        case notAHandle
        case noProfile
        /// The directory couldn't be asked, such as offline.
        case unavailable
    }

    /// Links a card to a handle, by hand, once the directory says there's a profile there. The server learns
    /// only that this handle was looked up, as it does when anyone opens a profile (section 3).
    public func link(_ card: ContactCard, to typed: String) async -> LinkResult {
        guard let handle = ContactCard.normalizedHandle(typed) else { return .notAHandle }
        if let profiles {
            do {
                guard try await profiles.profile(of: handle) != nil else { return .noProfile }
            } catch {
                return .unavailable
            }
        }
        var changed = card
        changed.username = handle
        guard let saved = await save(changed, over: card) else { return .unavailable }
        return .linked(saved)
    }

    public func unlink(_ card: ContactCard) async {
        var changed = card
        changed.username = nil
        await save(changed, over: card)
    }

    // MARK: Importing from iPhone Contacts

    /// Asks for access, only when the person taps Choose from iPhone Contacts.
    public func askForDeviceAccess() async -> DeviceAccess {
        guard let device else { return .denied }
        if device.access == .notAsked { deviceAccess = await device.requestAccess() } else { deviceAccess = device.access }
        return deviceAccess
    }

    /// The iPhone contacts Totality may see that haven't been copied yet.
    public func notYetCopied() async -> [DeviceContact] {
        guard let device else { return [] }
        do {
            let copied = Set(cards.compactMap { $0.origin?.deviceID })
            return try await device.all().filter { !copied.contains($0.id) }
        } catch {
            notice = "Totality can't see your iPhone contacts. You can still add contacts here, or allow access in Settings."
            return []
        }
    }

    /// Copies the chosen contacts, sealing each on the device as it's read. Progress shows as it goes.
    public func copy(_ chosen: [DeviceContact]) async {
        guard let vault, !chosen.isEmpty else { return }
        progress = Progress(done: 0, total: chosen.count)
        var failed = 0
        for contact in chosen {
            let card = contact.card(at: now).tidied()
            do {
                try await vault.save(card)
                cards.append(card)
            } catch {
                failed += 1
            }
            progress?.done += 1
        }
        progress = nil
        directory.update(cards)
        let copied = chosen.count - failed
        notice = failed == 0 ? "Copied \(copied) \(copied == 1 ? "contact" : "contacts") and encrypted \(copied == 1 ? "it" : "them") on this iPhone."
            : "\(failed) couldn't be copied. Try again."
    }

    /// What changed in iPhone Contacts since cards were copied, for Update from iPhone to show first.
    public func pendingUpdates() async -> [ContactUpdate] {
        guard let device else { return [] }
        let ids = cards.compactMap { $0.isDeleted ? nil : $0.origin?.deviceID }
        guard !ids.isEmpty, let contacts = try? await device.contacts(ids) else { return [] }
        return ContactUpdate.pending(cards, device: contacts)
    }

    /// Saves the updates the person chose to keep. Totality's own notes, labels and links stay.
    public func apply(_ updates: [ContactUpdate]) async {
        guard let vault else { return }
        var saved = 0
        for update in updates {
            guard let current = card(update.card.id) else { continue }
            var changed = current
            update.contact.apply(to: &changed, at: now)
            if let kept = try? await vault.save(changed.tidied(), over: current) {
                put(kept)
                saved += 1
            }
        }
        if saved > 0 { notice = "Updated \(saved) from iPhone Contacts." }
    }

    /// With two-way sync on: brings in what changed on the iPhone. Writing the other way happens on each save.
    public func syncWithDevice() async {
        guard twoWaySync, device?.access == .full || device?.access == .limited else { return }
        let updates = await pendingUpdates()
        guard !updates.isEmpty else { return }
        let before = notice
        await apply(updates)
        notice = before
    }

    private func writeBack(_ card: ContactCard) async {
        guard let device, let origin = card.origin else { return }
        do {
            try await device.update(DeviceContact.from(card, id: origin.deviceID))
            // The iPhone may tidy what it was given, so remember it as it now is.
            guard let after = try await device.contacts([origin.deviceID]).first, let vault else { return }
            var changed = card
            changed.origin = ContactCard.Origin(deviceID: origin.deviceID, copiedAt: now, fingerprint: after.fingerprint)
            if let kept = try? await vault.save(changed, over: card) { put(kept) }
        } catch {
            notice = "Saved here, but iPhone Contacts couldn't be changed."
        }
    }

    // MARK: Actions

    /// A new task about this person, such as "Ask Sam about the rope". The task links back to the card.
    public func taskDraft(for card: ContactCard) -> TaskDraft {
        TaskDraft(title: "", source: TaskSource(module: .contacts, itemID: card.id.uuidString, title: card.shownName))
    }

    /// The card as a vCard file in this device's temporary folder, for the share sheet.
    public func vCardFile(_ card: ContactCard, options: VCard.Options) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SharedCards", isDirectory: true)
        let file = folder.appendingPathComponent(VCard.fileName(card))
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(VCard.text(card, options: options).utf8).write(to: file, options: .atomic)
            return file
        } catch {
            notice = "The card couldn't be shared. Try again."
            return nil
        }
    }

    /// Opens a request from search, a ref or the Calendar.
    public func takeRequest() -> ContactCard? {
        guard let id = requestedCard else { return nil }
        requestedCard = nil
        return card(id)
    }
}
