import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

private let denver = TimeZone(identifier: "America/Denver")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
private let london = TimeZone(identifier: "Europe/London")!

/// A moment, written as the wall clock in `zone` shows it.
private func at(_ text: String, in zone: TimeZone) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

private func utc(_ text: String) -> Date {
    at(text, in: TimeZone(identifier: "UTC")!)
}

@Suite struct JournalClockTests {
    @Test("Writing before 4 a.m. belongs to the day before")
    func dayStartsAtFour() {
        #expect(JournalClock.day(of: at("2026-11-20 23:30", in: denver), in: denver) == "2026-11-20")
        #expect(JournalClock.day(of: at("2026-11-21 03:59", in: denver), in: denver) == "2026-11-20")
        #expect(JournalClock.day(of: at("2026-11-21 04:00", in: denver), in: denver) == "2026-11-21")
        // The first of the month at 2 a.m. is still the last day of the one before.
        #expect(JournalClock.day(of: at("2026-12-01 02:00", in: denver), in: denver) == "2026-11-30")
        #expect(JournalClock.day(of: at("2027-01-01 01:00", in: denver), in: denver) == "2026-12-31")
    }

    @Test("A day locks at 4 a.m. by the wall clock across both daylight saving changes")
    func daylightSaving() throws {
        // The clocks went forward at 2 a.m. on March 8, 2026: 4 a.m. that morning is daylight time.
        let spring = try #require(JournalClock.locks(day: "2026-03-07", zone: denver))
        #expect(spring == utc("2026-03-08 10:00"))
        // And back at 2 a.m. on November 1: 4 a.m. is standard time, so that day ran 25 hours.
        let autumn = try #require(JournalClock.locks(day: "2026-10-31", zone: denver))
        #expect(autumn == utc("2026-11-01 11:00"))
        let before = try #require(JournalClock.locks(day: "2026-10-30", zone: denver))
        #expect(autumn.timeIntervalSince(before) == 25 * 60 * 60)
        // London changes at 1 a.m., and its day still ends at 4.
        #expect(JournalClock.locks(day: "2026-03-28", zone: london) == utc("2026-03-29 03:00"))
        #expect(JournalClock.day(of: utc("2026-03-29 02:30"), in: london) == "2026-03-28")
    }

    @Test("An entry stays in the zone it was started in, wherever the person goes")
    func timeZoneChange() {
        let stamp = JournalStamp(day: "2026-11-20", zone: denver.identifier)
        // 4 a.m. in Denver, whatever this device's clock says now.
        #expect(stamp.locksAt == utc("2026-11-21 11:00"))
        #expect(!stamp.isClosed(at: utc("2026-11-21 10:59")))
        #expect(stamp.isClosed(at: utc("2026-11-21 11:00")))
    }

    @Test("The streak counts days running that end today or yesterday")
    func streak() {
        let days: Set = ["2026-11-12", "2026-11-13", "2026-11-14"]
        #expect(JournalClock.streak(days: days, today: "2026-11-14") == 3)
        #expect(JournalClock.streak(days: days, today: "2026-11-15") == 3)
        #expect(JournalClock.streak(days: days, today: "2026-11-16") == 0)
        #expect(JournalClock.streak(days: [], today: "2026-11-16") == 0)
    }

    @Test("Headings and short dates name the day itself in any zone")
    func names() {
        #expect(JournalClock.heading("2026-11-20") == "Friday, November 20, 2026")
        #expect(JournalClock.short("2026-11-20") == "Nov 20")
        #expect(JournalClock.day("2026-12-31", adding: 1) == "2027-01-01")
        #expect(JournalClock.components("2026-13-01") == nil)
    }
}

@Suite struct JournalVaultTests {
    let key: ContentRootKey
    let vault: ReaderVault

    init() throws {
        key = try ContentRootKey.generate()
        vault = ReaderVault(store: MemoryBlobStore(), rootKey: key)
    }

    private func write(_ text: String, at now: Date, in zone: TimeZone = denver, on vault: ReaderVault? = nil) async throws -> ReaderItem {
        let vault = vault ?? self.vault
        let draft = try await vault.journalToday(now: now, zone: zone)
        let current = try? await vault.item(draft.id)
        guard case .saved(let saved) = try await vault.saveJournal(current ?? draft, body: text, basedOn: (current ?? draft).updatedAt, now: now) else {
            Issue.record("Kept as a copy")
            return draft
        }
        return saved
    }

    @Test("Your journal starts empty, and a day with nothing written leaves nothing behind")
    func empty() async throws {
        let now = at("2026-11-20 09:00", in: denver)
        let today = try await vault.journalToday(now: now, zone: denver)
        #expect(today.journal?.day == "2026-11-20")
        _ = try await vault.saveJournal(today, body: "", basedOn: today.updatedAt, now: now)
        #expect(try await vault.journal(now: now) == .empty)
        #expect(try await vault.sealedObjectIDs().isEmpty)
    }

    @Test("Today's entry is kept, apart from the library, and search finds it")
    func todayIsKeptApart() async throws {
        let now = at("2026-11-20 21:15", in: denver)
        let entry = try await write("Climbed the north ridge with Priya before the storm came in.", at: now)
        #expect(try await vault.list().items.isEmpty)
        let journal = try await vault.journal(now: now)
        #expect(journal.entries.map(\.id) == [entry.id])
        #expect(journal.days == ["2026-11-20"])
        let hits = try await vault.search("north ridge")
        #expect(hits.map(\.item.id) == [entry.id])
        // The same day on another of this person's devices is the same entry.
        let other = ReaderVault(store: MemoryBlobStore(), rootKey: key)
        #expect(try await other.journalToday(now: now, zone: denver).id == entry.id)
    }

    @Test("A day that's over can't be edited from the editor")
    func closedRefusesEdits() async throws {
        let entry = try await write("Bread rose overnight.", at: at("2026-11-20 22:00", in: denver))
        let late = at("2026-11-21 04:01", in: denver)
        let current = try await vault.item(entry.id)
        await #expect(throws: ReaderError.journalClosed) {
            try await vault.saveJournal(current, body: "Changed later.", basedOn: current.updatedAt, now: late)
        }
        #expect(try await vault.journalText(of: entry.id) == "Bread rose overnight.")
        // At 3:59 the same night it still takes changes.
        let stillOpen = try await vault.saveJournal(current, body: "Bread rose overnight. Baked at 3.", basedOn: current.updatedAt, now: at("2026-11-21 03:59", in: denver))
        guard case .saved = stillOpen else { Issue.record("Refused before 4 a.m."); return }
        // The morning brings a fresh entry.
        #expect(try await vault.journalToday(now: late, zone: denver).journal?.day == "2026-11-21")
    }

    @Test("A journal entry can't be renamed, moved, or shared")
    func private_() async throws {
        let entry = try await write("Private.", at: at("2026-11-20 10:00", in: denver))
        await #expect(throws: ReaderError.journalIsPrivate) { try await vault.rename(entry.id, to: "Public") }
        await #expect(throws: ReaderError.journalIsPrivate) { try await vault.move(entry.id, to: nil) }
        await #expect(throws: ReaderError.journalIsPrivate) { try await vault.share(entry.id, with: try IdentityKeys.generate().bundle()) }
        #expect(try await ReaderModule(vault: vault).current(ContentRef(
            module: .reader, kind: .note, id: entry.id, keyRef: .crk(objectID: entry.id), preview: .init(title: "")
        )) == nil)
    }

    @Test("Flying west after a day locked opens the next day, and never reopens the old one")
    func travelWest() async throws {
        let entry = try await write("Left Denver.", at: at("2026-11-20 20:00", in: denver))
        // 4:30 a.m. in Denver is 1:30 a.m. in Honolulu, still the 20th there.
        let landed = at("2026-11-21 04:30", in: denver)
        #expect(JournalClock.day(of: landed, in: honolulu) == "2026-11-20")
        let today = try await vault.journalToday(now: landed, zone: honolulu)
        #expect(today.id != entry.id)
        #expect(today.journal?.day == "2026-11-21")
        #expect(today.journal?.zone == honolulu.identifier)
    }

    @Test("Flying east keeps the entry in its own zone, and the new day opens by the local clock")
    func travelEast() async throws {
        let entry = try await write("Packing.", at: at("2026-11-20 09:00", in: denver))
        // 6 p.m. in Denver is 10 a.m. the next day in Tokyo.
        let landed = at("2026-11-20 18:00", in: denver)
        let today = try await vault.journalToday(now: landed, zone: tokyo)
        #expect(today.journal?.day == "2026-11-21")
        // The Denver entry still locks at 4 a.m. in Denver.
        #expect(try await vault.item(entry.id).journal?.locksAt == at("2026-11-21 04:00", in: denver))
    }

    @Test("A clock set back after a day ended can't reopen it")
    func clockSetBack() async throws {
        let entry = try await write("Ran 10 km.", at: at("2026-11-20 07:00", in: denver))
        _ = try await vault.journal(now: at("2026-11-21 05:00", in: denver))
        let marked = try await vault.item(entry.id)
        #expect(marked.journal?.closedAt == at("2026-11-21 04:00", in: denver))
        // Locking isn't an edit.
        #expect(marked.updatedAt == at("2026-11-20 07:00", in: denver))
        await #expect(throws: ReaderError.journalClosed) {
            try await vault.saveJournal(marked, body: "Ran 20 km.", basedOn: marked.updatedAt, now: at("2026-11-20 08:00", in: denver))
        }
    }

    @Test("A note under a past day is kept beside it, and locks at the end of its own day")
    func notesLockAtTheirOwnDayEnd() async throws {
        _ = try await write("Interview went well.", at: at("2026-11-20 18:00", in: denver))
        let added = at("2026-11-22 12:00", in: denver)
        let note = try await vault.journalNote(under: "2026-11-20", now: added, zone: denver)
        #expect(note.journal?.day == "2026-11-22")
        #expect(note.journal?.about == "2026-11-20")
        guard case .saved(let kept) = try await vault.saveJournal(note, body: "They called back with an offer.", basedOn: note.updatedAt, now: added) else {
            Issue.record("Kept as a copy")
            return
        }
        let journal = try await vault.journal(now: added)
        #expect(journal.notes["2026-11-20"]?.map(\.id) == [kept.id])
        // Still open that evening, closed at 4 a.m. after its own day.
        let evening = try await vault.saveJournal(kept, body: "They called back with an offer. Starting in January.", basedOn: kept.updatedAt, now: at("2026-11-22 23:00", in: denver))
        guard case .saved(let later) = evening else { Issue.record("Refused in its own day"); return }
        await #expect(throws: ReaderError.journalClosed) {
            try await vault.saveJournal(later, body: "Changed.", basedOn: later.updatedAt, now: at("2026-11-23 04:00", in: denver))
        }
        // A note can only go under a day before today.
        await #expect(throws: ReaderError.notFound) { try await vault.journalNote(under: "2026-11-22", now: added, zone: denver) }
    }

    @Test("A save from an editor that fell behind keeps what was typed as a note under the day")
    func staleEditor() async throws {
        let now = at("2099-03-03 10:00", in: denver)
        let first = try await write("Morning.", at: now)
        _ = try await vault.saveJournal(first, body: "Morning, from the Mac.", basedOn: first.updatedAt, now: now.addingTimeInterval(60))
        let result = try await vault.saveJournal(first, body: "Morning, from the phone.", basedOn: first.updatedAt, now: now.addingTimeInterval(120))
        guard case .keptAsCopy(let copy) = result else { Issue.record("Overwrote the newer save"); return }
        #expect(try await vault.journalText(of: first.id) == "Morning, from the Mac.")
        #expect(try await vault.journalText(of: copy.id) == "Morning, from the phone.")
        #expect(copy.journal?.about == "2099-03-03")
    }
}

@Suite struct JournalSyncTests {
    let key: ContentRootKey

    init() throws {
        key = try ContentRootKey.generate()
    }

    private func device() -> ReaderVault {
        ReaderVault(store: MemoryBlobStore(), rootKey: key)
    }

    private func send(_ id: UUID, from source: ReaderVault, to target: ReaderVault) async throws {
        let object = try #require(try await source.sealedObject(id))
        try await target.store(object, ifLocalHash: try await target.sealedHash(of: id))
    }

    /// The real clock, for these: the vault judges what sync brings by the time it is now. A day long past is closed.
    private func save(_ text: String, on vault: ReaderVault, day: String, hour: Int) async throws -> ReaderItem {
        let now = at("\(day) \(String(format: "%02d", hour)):00", in: denver)
        let draft = try await vault.journalToday(now: now, zone: denver)
        let current = try? await vault.item(draft.id)
        guard case .saved(let saved) = try await vault.saveJournal(current ?? draft, body: text, basedOn: (current ?? draft).updatedAt, now: now) else {
            throw ReaderError.notANote
        }
        return saved
    }

    @Test("A closed entry's words can't be overwritten by an older copy from sync")
    func closedRejectsOlderCopies() async throws {
        let phone = device()
        let mac = device()
        let first = try await save("Snow all day.", on: phone, day: "2026-11-01", hour: 9)
        try await send(first.id, from: phone, to: mac)
        _ = try await save("Snow all day. Shovelled twice.", on: phone, day: "2026-11-01", hour: 21)
        // The Mac still has the morning's copy, and offers it back.
        try await send(first.id, from: mac, to: phone)
        #expect(try await phone.journalText(of: first.id) == "Snow all day. Shovelled twice.")
        // Since its copy here wasn't replaced, the next sync sends the locked one back.
        #expect(try await phone.sealedHash(of: first.id) != mac.sealedHash(of: first.id))
        // Clocks can be wrong, so what the Mac had is kept as a note under the day, once however often it comes.
        try await send(first.id, from: mac, to: phone)
        let notes = try await phone.journal().notes["2026-11-01"] ?? []
        #expect(notes.count == 1)
        #expect(try await phone.journalText(of: try #require(notes.first).id) == "Snow all day.")
    }

    @Test("An edit made before the day ended that arrives late still lands")
    func lateEditInTime() async throws {
        let phone = device()
        let mac = device()
        let first = try await save("Quiet day.", on: phone, day: "2026-11-02", hour: 9)
        try await send(first.id, from: phone, to: mac)
        _ = try await save("Quiet day. Finished the chapter.", on: mac, day: "2026-11-02", hour: 23)
        try await send(first.id, from: mac, to: phone)
        #expect(try await phone.journalText(of: first.id) == "Quiet day. Finished the chapter.")
    }

    @Test("Two copies of a closed day keep the one written in time, and the other becomes a note under it")
    func conflictKeepsBoth() async throws {
        let phone = device()
        let mac = device()
        let first = try await save("Started.", on: phone, day: "2026-11-03", hour: 8)
        try await send(first.id, from: phone, to: mac)
        _ = try await save("Started. Phone.", on: phone, day: "2026-11-03", hour: 20)
        _ = try await save("Started. Mac.", on: mac, day: "2026-11-03", hour: 22)
        let local = try #require(try await phone.verifiedObject(first.id))
        let remote = try #require(try await mac.verifiedObject(first.id))
        #expect(try await phone.resolveConflict(local: local, remote: remote) == .keepRemote)
        let notes = try await phone.journal().notes["2026-11-03"] ?? []
        #expect(notes.count == 1)
        let copy = try #require(notes.first)
        #expect(try await phone.journalText(of: copy.id) == "Started. Phone.")
        // The copy stays in the journal, and is as locked as its day.
        #expect(copy.kind == .journal)
        #expect(copy.journal?.isClosed(at: Date()) == true)
        #expect(try await phone.list().items.isEmpty)
    }

    @Test("Only the details around a closed day's words may change, like where Listen stopped")
    func detailsStillSync() async throws {
        let phone = device()
        let mac = device()
        let first = try await save("Listened to the rain.", on: phone, day: "2026-11-04", hour: 10)
        try await send(first.id, from: phone, to: mac)
        try await mac.setListenPosition(12, of: first.id)
        try await send(first.id, from: mac, to: phone)
        #expect(try await phone.item(first.id).listenPosition == 12)
    }
}

@Suite struct JournalTwoUserTests {
    @Test("User 2 can't open User 1's journal, from the device or from sync")
    func twoUsers() async throws {
        let store = MemoryBlobStore()
        let user1 = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        let now = at("2026-11-20 21:00", in: denver)
        let draft = try await user1.journalToday(now: now, zone: denver)
        _ = try await user1.saveJournal(draft, body: "Told nobody about the move yet.", basedOn: draft.updatedAt, now: now)
        for name in try store.names() {
            let blob = try #require(try store.read(name))
            #expect(blob.range(of: Data("move".utf8)) == nil)
            #expect(blob.range(of: Data("journal".utf8)) == nil)
            #expect(blob.range(of: Data("2026-11-20".utf8)) == nil)
        }
        let user2 = ReaderVault(store: store, rootKey: try ContentRootKey.generate())
        #expect(try await user2.journal(now: now) == .empty)
        await #expect(throws: CryptoError.self) { try await user2.journalText(of: draft.id) }
        // User 2's day has a different ID, so the same date never lands on User 1's entry.
        #expect(try await user2.journalToday(now: now, zone: denver).id != draft.id)
        let object = try #require(try await user1.sealedObject(draft.id))
        #expect(object.kind == .note)
        let theirs = ReaderVault(store: MemoryBlobStore(), rootKey: try ContentRootKey.generate())
        await #expect(throws: CryptoError.self) { try await theirs.store(object, ifLocalHash: nil) }
    }
}

private final class JournalKeys: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]
    func load(_ name: String) throws -> Data? { lock.withLock { secrets[name] } }
    func save(_ data: Data, as name: String) throws { lock.withLock { secrets[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { secrets.removeValue(forKey: name) } }
}

@Suite struct JournalKeyMoveTests {
    @Test("After a change of key, every day is still in the journal, and today's entry is the one already there")
    func keyMove() async throws {
        let files = try FileBlobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)"))
        let ring = ContentKeyRing(keys: JournalKeys(), areas: [
            SealedArea(files: files, purposes: ReaderVault.sealedPurposes, chunked: ReaderVault.chunkedPurposes),
        ])
        let vault = ReaderVault(store: files, rootKey: try ring.current())
        let now = at("2099-05-01 20:00", in: denver)
        let draft = try await vault.journalToday(now: now, zone: denver)
        _ = try await vault.saveJournal(draft, body: "Planted the tomatoes.", basedOn: draft.updatedAt, now: now)
        await vault.close()

        let new = try ContentRootKey.generate()
        #expect(try ring.adopt(new).unreadable == 0)
        let moved = ReaderVault(store: files, rootKey: new)
        let journal = try await moved.journal(now: now)
        #expect(journal.entries.map(\.id) == [draft.id])
        let today = try await moved.journalToday(now: now, zone: denver)
        #expect(today.id == draft.id)
        guard case .saved = try await moved.saveJournal(today, body: "Planted the tomatoes. Watered.", basedOn: today.updatedAt, now: now) else {
            Issue.record("Kept as a copy")
            return
        }
        #expect(try await moved.journalText(of: draft.id) == "Planted the tomatoes. Watered.")
    }
}
