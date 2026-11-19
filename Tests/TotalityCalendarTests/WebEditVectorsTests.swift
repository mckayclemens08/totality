import Foundation
import Testing
import TotalityCore
@testable import TotalityCalendar

/// The website edits events too (PR "edit Calendar on the website"). Two files keep both sides honest:
/// - docs/calendar-edit-vectors.json is made here, by the real CalendarModel and CalendarVault: what creating,
///   editing "this event only" or "all of them", deleting, repeating and conflicts give. The website's tests
///   run the same steps and must get the same events.
/// - docs/calendar-web-vectors.json is made by the website. Every event in it must open in the real
///   CalendarVault with the fields it says, so what the browser seals is what the iPhone reads.
@MainActor
@Suite struct CalendarWebEditVectorsTests {
    static let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs")
    let key = try! ContentRootKey(bytes: Data((0..<32).map { UInt8(100 + $0) }))
    nonisolated static let now = Dates.date(2026, 10, 15, 8, 30)
    typealias Step = @MainActor (CalendarModel) async throws -> [String: Any]

    struct WebVectors: Decodable {
        struct Item: Decodable { let id: String; let meta: String; let hash: String; let expect: [String: JSONValue] }
        let items: [Item]
        let conflicts: [Conflict]
        struct Conflict: Decodable { let mine: Int; let theirs: Int; let keep: String; let copyID: String? }
    }

    @Test func websiteWritesOpenInTheVault() async throws {
        let url = Self.docs.appendingPathComponent("calendar-web-vectors.json")
        let vectors = try JSONDecoder().decode(WebVectors.self, from: Data(contentsOf: url))
        #expect(!vectors.items.isEmpty)
        var objects: [SealedObject] = []
        for item in vectors.items {
            let vault = CalendarVault(store: MemoryBlobs(), rootKey: key)
            let id = try #require(UUID(uuidString: item.id))
            let object = SealedObject(id: id, kind: .event, meta: try #require(Data(base64Encoded: item.meta)), body: nil)
            #expect(object.hash == item.hash, "the website's row hash is SealedObject.hash")
            try await vault.store(object, ifLocalHash: nil)
            let event = try await vault.event(id)
            let encoded = try Self.json(event)
            for (field, want) in item.expect {
                #expect(JSONValue(encoded[field]) == want, "\(item.id) \(field)")
            }
            objects.append(object)
        }
        // The website's conflict rule is CalendarVault.resolveConflict.
        for conflict in vectors.conflicts {
            let store = MemoryBlobs()
            let vault = CalendarVault(store: store, rootKey: key)
            let mine = objects[conflict.mine], theirs = objects[conflict.theirs]
            try await vault.store(mine, ifLocalHash: nil)
            let kept = try await vault.resolveConflict(local: mine, remote: theirs)
            #expect(kept == (conflict.keep == "mine" ? .keepLocal : .keepRemote))
            let ids = try await vault.list().events.map { $0.id.uuidString }
            if let copy = conflict.copyID { #expect(ids.contains(copy)) } else { #expect(ids.count == 1) }
        }
    }

    // MARK: Making the iPhone's vectors

    private func model() -> (CalendarModel, CalendarVault, MemoryBlobs) {
        let blobs = MemoryBlobs()
        let vault = CalendarVault(store: blobs, rootKey: key)
        let model = CalendarModel(
            vault: vault, devices: FakeDevices(), reminders: FakeReminders(), startingMode: .schedule, display: Dates.calendar(),
            defaults: UserDefaults(suiteName: "totality.tests.\(UUID().uuidString)")!, now: { Self.now }
        )
        return (model, vault, blobs)
    }

    private func occurrence(_ model: CalendarModel, _ day: Int) throws -> EventOccurrence {
        let own = model.entries(on: CalendarDay(year: 2026, month: 10, day: day)).compactMap { entry -> EventOccurrence? in
            if case .own(let o) = entry.source { return o } else { return nil }
        }
        return try #require(own.first)
    }

    private static func json(_ draft: EventDraft) -> [String: Any] {
        var out: [String: Any] = [
            "title": draft.title, "location": draft.location, "notes": draft.notes,
            "start": draft.start.timeIntervalSinceReferenceDate, "end": draft.end.timeIntervalSinceReferenceDate, "isAllDay": draft.isAllDay,
        ]
        if let f = draft.frequency { out["frequency"] = f.rawValue }
        if let u = draft.until { let d = CalendarDay(u, in: Dates.calendar()); out["until"] = ["year": d.year, "month": d.month, "day": d.day] }
        if let m = draft.reminderMinutes { out["reminderMinutes"] = m }
        return out
    }

    private static func json(_ event: CalendarEvent) throws -> [String: Any] {
        var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        o["skipped"] = ((o["skipped"] as? [Double]) ?? []).sorted()
        return o
    }

    private func draft(_ title: String, day: Int = 15, hour: Int = 9, minutes: Int = 60) -> EventDraft {
        var d = EventDraft(start: Dates.date(2026, 10, day, hour), end: Dates.date(2026, 10, day, hour).addingTimeInterval(Double(minutes) * 60))
        d.title = title
        return d
    }

    /// One recorded case: the steps the person took, then every event the vault holds.
    private func record(_ name: String, _ steps: [Step]) async throws -> [String: Any] {
        let (model, _, _) = model()
        var done: [[String: Any]] = []
        for step in steps {
            model.notice = nil
            var s = try await step(model)
            await model.load()
            if let notice = model.notice { s["notice"] = notice }
            done.append(s)
        }
        let events = try model.events.sorted { ($0.start, $0.title) < ($1.start, $1.title) }.map(Self.json)
        return ["name": name, "steps": done, "events": events]
    }

    private func create(_ d: EventDraft) -> Step {
        { model in ["op": "create", "draft": Self.json(d), "saved": await model.create(d)] }
    }

    private func update(day: Int, _ scope: EditScope, _ change: @escaping (inout EventDraft) -> Void) -> Step {
        { model in
            let o = try self.occurrence(model, day)
            let before = model.draft(for: o)
            var d = before
            change(&d)
            let saved = await model.update(o, with: d, scope: scope)
            return ["op": "update", "day": day, "occurrenceStart": o.start.timeIntervalSinceReferenceDate, "scope": scope == .thisOccurrence ? "this" : "all",
                    "draftFor": Self.json(before), "draft": Self.json(d), "saved": saved]
        }
    }

    private func delete(day: Int, _ scope: EditScope) -> Step {
        { model in
            let o = try self.occurrence(model, day)
            await model.delete(o, scope: scope)
            return ["op": "delete", "day": day, "occurrenceStart": o.start.timeIntervalSinceReferenceDate, "scope": scope == .thisOccurrence ? "this" : "all"]
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOTALITY_MAKE_VECTORS"] != nil))
    func makeModelVectors() async throws {
        var cases: [[String: Any]] = []
        var daily = draft("Standup")
        daily.frequency = .daily
        var weekly = draft("  PHIL 4410  ", hour: 13, minutes: 50)
        weekly.location = " Room 210 "
        weekly.notes = "Bring the reading\n"
        weekly.frequency = .weekly
        weekly.until = Dates.date(2026, 12, 10)
        weekly.reminderMinutes = 15
        var allDay = draft("Conference", day: 20)
        allDay.isAllDay = true
        allDay.end = Dates.date(2026, 10, 22, 9)
        var monthly = draft("Rent", day: 31, hour: 8)
        monthly.frequency = .monthly
        var timed = draft("Dentist", day: 16, hour: 14)
        timed.reminderMinutes = 1_440

        cases.append(try await record("a weekly class with an end and a reminder", [create(weekly)]))
        cases.append(try await record("an all-day event over three days", [create(allDay)]))
        cases.append(try await record("one repeat changed on its own", [create(daily), update(day: 16, .thisOccurrence) { $0.title = "Standup with Sam"; $0.start = Dates.date(2026, 10, 16, 10); $0.end = Dates.date(2026, 10, 16, 10, 30) }]))
        cases.append(try await record("all repeats moved from a later one", [create(daily), update(day: 20, .allOccurrences) { $0.title = "Team standup"; $0.start = Dates.date(2026, 10, 20, 10); $0.end = Dates.date(2026, 10, 20, 11) }]))
        cases.append(try await record("a skipped day stays skipped when the series moves", [create(daily), delete(day: 17, .thisOccurrence), update(day: 15, .allOccurrences) { $0.start = Dates.date(2026, 10, 15, 11); $0.end = Dates.date(2026, 10, 15, 12) }]))
        cases.append(try await record("a series switched to all day starts again from there", [create(daily), delete(day: 16, .thisOccurrence), update(day: 18, .allOccurrences) { $0.isAllDay = true; $0.end = $0.start }]))
        cases.append(try await record("an all-day series switched back to timed", [create({ var d = allDay; d.frequency = .weekly; return d }()), update(day: 27, .allOccurrences) { $0.isAllDay = false; $0.start = Dates.date(2026, 10, 27, 9); $0.end = Dates.date(2026, 10, 27, 17) }]))
        cases.append(try await record("one repeat deleted", [create(daily), delete(day: 16, .thisOccurrence)]))
        cases.append(try await record("the whole series deleted", [create(daily), delete(day: 16, .allOccurrences)]))
        cases.append(try await record("a single event edited, its repeat and reminder changed", [create(timed), update(day: 16, .allOccurrences) { $0.frequency = .yearly; $0.reminderMinutes = nil; $0.notes = "Floss first" }]))
        cases.append(try await record("a repeat stopped", [create(weekly), update(day: 22, .allOccurrences) { $0.frequency = nil; $0.until = nil }]))
        cases.append(try await record("a repeat that ends before it starts is refused", [create({ var d = daily; d.until = Dates.date(2026, 10, 1); return d }())]))
        cases.append(try await record("an event that ends before it starts is refused", [create({ var d = timed; d.end = d.start.addingTimeInterval(-60); return d }())]))
        cases.append(try await record("monthly on the 31st", [create(monthly)]))

        // Occurrences: the 31st skips short months, and a weekly event keeps 9 AM through the clock change.
        var occurrences: [[String: Any]] = []
        let rent = CalendarEvent(title: "Rent", start: Dates.date(2026, 1, 31, 8), end: Dates.date(2026, 1, 31, 9), timeZoneID: "America/Denver", repeatRule: RepeatRule(frequency: .monthly))
        let class9 = CalendarEvent(title: "Class", start: Dates.date(2026, 10, 19, 9), end: Dates.date(2026, 10, 19, 10), timeZoneID: "America/Denver",
                                   repeatRule: RepeatRule(frequency: .weekly, until: CalendarDay(year: 2026, month: 11, day: 16)),
                                   skipped: [Dates.date(2026, 11, 2, 9)])
        let tokyo = CalendarEvent(title: "Call Kenji", start: Dates.date(2026, 10, 20, 9, zone: "Asia/Tokyo"), end: Dates.date(2026, 10, 20, 10, zone: "Asia/Tokyo"), timeZoneID: "Asia/Tokyo", repeatRule: RepeatRule(frequency: .daily))
        let leap = CalendarEvent(title: "Leap", start: Dates.date(2024, 2, 29, zone: "GMT"), end: Dates.date(2024, 2, 29, zone: "GMT"), isAllDay: true, timeZoneID: "GMT", repeatRule: RepeatRule(frequency: .yearly))
        for (event, from, through) in [(rent, CalendarDay(year: 2026, month: 1, day: 1), CalendarDay(year: 2026, month: 12, day: 31)),
                                       (class9, CalendarDay(year: 2026, month: 10, day: 1), CalendarDay(year: 2026, month: 12, day: 31)),
                                       (tokyo, CalendarDay(year: 2026, month: 10, day: 18), CalendarDay(year: 2026, month: 10, day: 22)),
                                       (leap, CalendarDay(year: 2024, month: 1, day: 1), CalendarDay(year: 2032, month: 12, day: 31))] {
            let found = event.occurrences(from: from, through: through, in: Dates.calendar())
            occurrences.append(["event": try Self.json(event), "from": ["year": from.year, "month": from.month, "day": from.day],
                                "through": ["year": through.year, "month": through.month, "day": through.day],
                                "starts": found.map { $0.start.timeIntervalSinceReferenceDate }])
        }

        // Conflicts: CalendarVault.resolveConflict, with the copy it keeps.
        var conflicts: [[String: Any]] = []
        let base = CalendarEvent(id: UUID(uuidString: "6C1A4B53-2F0E-4C83-9E7B-3D2A1F0E5C11")!, title: "Lunch with Ana", location: "Cafe Rio",
                                 start: Dates.date(2026, 10, 21, 12), end: Dates.date(2026, 10, 21, 13), timeZoneID: "America/Denver",
                                 createdAt: Dates.date(2026, 10, 1), updatedAt: Dates.date(2026, 10, 2))
        var phone = base; phone.title = "Lunch with Ana and Sam"; phone.updatedAt = Dates.date(2026, 10, 3)
        var other = base; other.location = "Bakery"; other.updatedAt = Dates.date(2026, 10, 4)
        var same = base; same.updatedAt = Dates.date(2026, 10, 5)
        for (mine, theirs) in [(phone, other), (other, phone), (base, same)] {
            let (_, vault, _) = model()
            try await vault.save(mine)
            let local = try #require(try await vault.sealedObject(mine.id))
            let remoteVault = CalendarVault(store: MemoryBlobs(), rootKey: key)
            try await remoteVault.save(theirs)
            let remote = try #require(try await remoteVault.sealedObject(theirs.id))
            let kept = try await vault.resolveConflict(local: local, remote: remote)
            let copy = try await vault.list().events.first { $0.id != mine.id }
            conflicts.append(["mine": try Self.json(mine), "theirs": try Self.json(theirs), "mineHash": local.hash, "theirsHash": remote.hash,
                              "keep": kept == .keepLocal ? "mine" : "theirs", "copy": try copy.map(Self.json) ?? NSNull()])
        }

        let out: [String: Any] = [
            "note": "Made by CalendarWebEditVectorsTests.makeModelVectors from the real CalendarModel and CalendarVault, America/Denver.",
            "now": Self.now.timeIntervalSinceReferenceDate, "display": "America/Denver",
            "cases": cases, "occurrences": occurrences, "conflicts": conflicts,
        ]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: Self.docs.appendingPathComponent("calendar-edit-vectors.json"))
    }
}

/// A JSON value that compares the way the files mean it: numbers as numbers, objects by key.
enum JSONValue: Decodable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue($0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue($0) })
        default: self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
}
