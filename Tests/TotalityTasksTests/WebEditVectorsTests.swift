import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

/// Website editing, both ways (issue 150).
///  - docs/tasks-edit-vectors.json is made here by the real model: rich sealed tasks and lists, repeat
///    dates, next copies, skips, quick add and edit stamps. The website's tests must match every one.
///  - docs/tasks-web-vectors.json is made by the website's own code (web/site/test/make-tasks-vectors.mjs).
///    This opens each item in the real TaskVault and checks every part reads as the website meant.
@Suite struct TasksWebEditVectorsTests {
    static let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs")
    let key = try! ContentRootKey(bytes: Data((0..<32).map { UInt8(100 + $0) }))
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Denver")!
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = 1
        return c
    }
    static let made = Date(timeIntervalSinceReferenceDate: 785_000_000)

    // MARK: - The website's writes, read by the real vault

    struct WebItem: Codable { let id: String; let kind: String; let meta: String; var hash: String? = nil; let expect: [String: String] }
    struct WebVectors: Codable { let note: String; let rootKey: String; let items: [WebItem] }

    @Test func websiteWritesOpenInTheVault() async throws {
        let vectors = try JSONDecoder().decode(WebVectors.self, from: Data(contentsOf: Self.docs.appendingPathComponent("tasks-web-vectors.json")))
        #expect(vectors.items.count >= 6)
        let cal = Self.calendar
        for item in vectors.items {
            let vault = TaskVault(store: MemoryBlobs(), rootKey: key)
            let id = try #require(UUID(uuidString: item.id))
            let kind: ContentKind = item.kind == "task" ? .task : .taskList
            // store() proves it opens under this key, as this kind, with the same ID inside.
            let object = SealedObject(id: id, kind: kind, meta: try #require(Data(base64Encoded: item.meta)), body: nil)
            #expect(object.hash == item.hash, "the row hash the website sends is SealedObject.hash")
            try await vault.store(object, ifLocalHash: nil)
            if kind == .taskList {
                let list = try await vault.list(id)
                let seen: [String: String] = [
                    "name": list.name, "kind": list.kind.rawValue, "headings": list.headings.map(\.title).joined(separator: "|"),
                    "rules": list.rules.map { "\($0.match.rawValue):" + $0.rules.map { "\($0.kind.rawValue)\($0.isNegated ? "!" : "")=\($0.tag ?? $0.days.map(String.init) ?? $0.priority.map { String($0.rawValue) } ?? "")" }.joined(separator: ",") } ?? "",
                    "pinned": String(list.isPinned), "status": list.status.rawValue, "area": list.areaID?.uuidString.lowercased() ?? "",
                    "deadline": list.deadline.map { "\($0.year)-\($0.month)-\($0.day)" } ?? "",
                ]
                for (k, v) in item.expect { #expect(seen[k] == v, "\(item.id) \(k)") }
                continue
            }
            let task = try await vault.task(id)
            let seen: [String: String] = [
                "title": task.title, "notes": task.notes, "place": task.place.rawValue, "priority": String(task.priority.rawValue),
                "when": task.when.map { "\($0.year)-\($0.month)-\($0.day)" } ?? "", "evening": String(task.isEvening),
                "time": task.time.map { "\($0.hour):\($0.minute)" } ?? "", "deadline": task.deadline.map { "\($0.year)-\($0.month)-\($0.day)" } ?? "",
                "deadlineTime": task.deadlineTime.map { "\($0.hour):\($0.minute)" } ?? "",
                "steps": task.checklist.map { "\($0.title)\($0.isDone ? "+" : "")" }.joined(separator: "|"), "tags": task.tags.joined(separator: ","),
                "list": task.listID?.uuidString.lowercased() ?? "", "heading": task.headingID?.uuidString.lowercased() ?? "",
                "done": String(task.isCompleted), "repeat": task.repeatRule?.summary(in: cal) ?? "",
                "repeatEnd": task.repeatRule.map { "\($0.end)" } ?? "", "repeatDone": task.repeatRule.map { String($0.done) } ?? "",
                "reminders": task.reminders.map { "\($0.kind)" }.joined(separator: "|"), "nagging": task.nagging.map { "\($0.everyMinutes)/\($0.giveUp)" } ?? "",
                "snoozed": task.snoozedUntil.map { String(Int($0.timeIntervalSinceReferenceDate)) } ?? "", "block": task.blockMinutes.map(String.init) ?? "",
                "edited": task.edits.keys.sorted().joined(separator: ","), "unknownKept": task.edits["futurePart"] != nil ? "yes" : "no",
                "source": task.source?.title ?? "",
            ]
            for (k, v) in item.expect where k != "mergeBase" { #expect(seen[k] == v, "\(item.id) \(k): \(seen[k] ?? "nil") ≠ \(v)") }
        }
    }

    /// A web edit and a phone edit to different parts of the same task both survive the phone's merge.
    @Test func websiteEditsMergeWithPhoneEdits() async throws {
        let vectors = try JSONDecoder().decode(WebVectors.self, from: Data(contentsOf: Self.docs.appendingPathComponent("tasks-web-vectors.json")))
        let edited = try #require(vectors.items.first { $0.expect["mergeBase"] != nil })
        let base = try #require(vectors.items.first { $0.id == edited.expect["mergeBase"] && $0.meta != edited.meta })
        let vault = TaskVault(store: MemoryBlobs(), rootKey: key)
        let id = try #require(UUID(uuidString: base.id))
        try await vault.store(SealedObject(id: id, kind: .task, meta: Data(base64Encoded: base.meta)!, body: nil), ifLocalHash: nil)
        let original = try await vault.task(id)
        var phone = original
        phone.priority = .low
        phone.noteChanges(from: original, at: Self.made.addingTimeInterval(500))
        let web = try JSONDecoder().decode(TaskItem.self, from: ContentCipher.open(Data(base64Encoded: edited.meta)!, key: key.objectKey(for: id, purpose: .task), objectID: id))
        let merged = phone.merged(with: web)
        #expect(merged == web.merged(with: phone), "the same either way round")
        #expect(merged.title == web.title, "the website's newer title")
        #expect(merged.priority == .low, "the phone's priority")
    }

    // MARK: - The real model's answers, for the website to match

    struct RepeatCase: Codable { let rule: String; let after: TaskDay; let completed: TaskDay?; let next: TaskDay?; let summary: String }
    struct CopyCase: Codable { let task: String; let completedAt: Double; let result: String?; let followingID: String? }
    struct SkipCase: Codable { let task: String; let result: String? }
    struct QuickCase: Codable {
        let text: String; let title: String; let when: TaskDay?; let evening: Bool; let time: String?; let deadline: TaskDay?
        let tags: [String]; let priority: Int; let place: String?; let pieces: [String]
    }
    struct EditCase: Codable { let old: String; let new: String; let at: Double; let result: String }
    struct ModelVectors: Codable {
        let note: String; let rootKey: String; let timeZone: String; let now: Double
        let tasks: [WebItem]; let repeats: [RepeatCase]; let copies: [CopyCase]; let skips: [SkipCase]; let quickAdd: [QuickCase]; let edits: [EditCase]
    }

    static func json<T: Encodable>(_ v: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return String(decoding: try e.encode(v), as: UTF8.self)
    }

    static func rules() -> [RepeatRule] {
        let start = TaskDay(year: 2026, month: 11, day: 18)
        return [
            RepeatRule(kind: .daily, start: start),
            RepeatRule(kind: .daily, interval: 3, start: start, skipped: [TaskDay(year: 2026, month: 11, day: 21)]),
            RepeatRule(kind: .weekly, weekdays: [2, 4, 6], start: start),
            RepeatRule(kind: .custom, interval: 2, customUnit: .week, weekdays: [2, 5], start: start),
            RepeatRule(kind: .monthly, monthDays: [31], start: TaskDay(year: 2026, month: 1, day: 31)),
            RepeatRule(kind: .monthly, monthDays: [-1, 15], start: start),
            RepeatRule(kind: .monthly, monthWeekday: .init(ordinal: -1, weekday: 6), start: start),
            RepeatRule(kind: .monthly, interval: 3, monthWeekday: .init(ordinal: 2, weekday: 3), start: start),
            RepeatRule(kind: .yearly, start: TaskDay(year: 2024, month: 2, day: 29)),
            RepeatRule(kind: .afterFinish, interval: 2, customUnit: .week, start: start),
            RepeatRule(kind: .afterFinish, interval: 1, customUnit: .month, countFrom: .dueDate, start: start),
            RepeatRule(kind: .weekly, end: .on(TaskDay(year: 2026, month: 11, day: 30)), start: start),
            RepeatRule(kind: .daily, end: .after(times: 3), start: start, done: 2),
            RepeatRule(kind: .custom, interval: 10, customUnit: .day, start: start),
            RepeatRule(kind: .weekly, weekdays: [2, 3, 4, 5, 6], start: start),
        ]
    }

    static func richTask(_ cal: Calendar) -> TaskItem {
        var t = TaskItem(id: UUID(uuidString: "6F1C3A52-0B7E-4D1A-9C33-2E5B8A1D4F60")!, title: "Water the garden boxes", notes: "Both boxes, and the *basil*.",
                         place: .anytime, when: TaskDay(year: 2026, month: 11, day: 18), isEvening: false, time: TaskTime(hour: 7, minute: 30),
                         deadline: TaskDay(year: 2026, month: 11, day: 20), checklist: [.init(title: "Front", isDone: true), .init(title: "Back")],
                         tags: ["home", "garden/boxes"], priority: .medium, order: 4, createdAt: made)
        t.deadlineTime = TaskTime(hour: 17)
        t.repeatRule = RepeatRule(kind: .custom, interval: 2, customUnit: .week, weekdays: [2, 5], end: .after(times: 10), start: TaskDay(year: 2026, month: 11, day: 16), done: 1)
        t.reminders = [
            TaskReminder(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, kind: .at(TaskDay(year: 2026, month: 11, day: 18), TaskTime(hour: 7, minute: 15)!)),
            TaskReminder(id: UUID(uuidString: "11111111-2222-4333-8444-666666666666")!, kind: .beforeDeadline(.hour)),
            TaskReminder(id: UUID(uuidString: "11111111-2222-4333-8444-777777777777")!, kind: .place(ReminderPlace(name: "Home", latitude: 40.25, longitude: -111.65, radius: 100, onArrival: false))),
        ]
        t.nagging = Nagging(everyMinutes: 10, giveUp: .afterHours(2))
        t.snoozedUntil = made.addingTimeInterval(3600)
        t.blockMinutes = 45
        t.source = TaskSource(module: .reader, itemID: "abc", title: "Garden notes", quote: "water early")
        t.edits = ["title": made.addingTimeInterval(10), "futurePart": made.addingTimeInterval(20)]
        t.updatedAt = made.addingTimeInterval(20)
        return t
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOTALITY_MAKE_VECTORS"] != nil))
    func makeModelVectors() async throws {
        let cal = Self.calendar
        let vault = TaskVault(store: MemoryBlobs(), rootKey: key)
        // Sealed items with every part filled in.
        let rich = Self.richTask(cal)
        var project = TaskList(name: "Seminar paper", kind: .project, headings: [.init(title: "Research"), .init(title: "Drafting")],
                               deadline: TaskDay(year: 2026, month: 12, day: 4), createdAt: Self.made)
        project.areaID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")
        let smart = TaskList(name: "Due this week", kind: .smart, rules: SmartRules(match: .any, rules: [
            SmartRule(kind: .deadline, days: 7), SmartRule(kind: .tag, isNegated: true, tag: "someday"), SmartRule(kind: .priority, priority: .high),
        ]), isPinned: true, createdAt: Self.made)
        var tasks: [WebItem] = []
        try await vault.save(rich)
        tasks.append(WebItem(id: rich.id.uuidString.lowercased(), kind: "task", meta: try #require(try await vault.sealedObject(rich.id)).meta.base64EncodedString(), expect: [:]))
        for list in [project, smart] {
            try await vault.save(list)
            tasks.append(WebItem(id: list.id.uuidString.lowercased(), kind: "task_list", meta: try #require(try await vault.sealedObject(list.id)).meta.base64EncodedString(), expect: ["name": list.name]))
        }

        var repeats: [RepeatCase] = []
        for rule in Self.rules() {
            var after = rule.start
            for _ in 0..<4 {
                let next = rule.next(after: after, completed: after.adding(days: 3, in: cal), in: cal)
                repeats.append(RepeatCase(rule: try Self.json(rule), after: after, completed: after.adding(days: 3, in: cal), next: next, summary: rule.summary(in: cal)))
                guard let next else { break }
                after = next
            }
        }

        var copies: [CopyCase] = []
        var skips: [SkipCase] = []
        var plain = rich
        plain.when = nil
        let finished = Self.made.addingTimeInterval(86_400 * 3)
        for task in [rich, plain] {
            let copy = TaskRepeats.following(task, completedAt: finished, in: cal)
            copies.append(CopyCase(task: try Self.json(task), completedAt: finished.timeIntervalSinceReferenceDate, result: try copy.map(Self.json),
                                   followingID: copy?.id.uuidString))
            skips.append(SkipCase(task: try Self.json(task), result: try TaskRepeats.skippingNext(task, in: cal).map(Self.json)))
        }

        let now = Date(timeIntervalSinceReferenceDate: 816_000_000 + 4 * 3600) // a Wednesday in Denver
        let phrases = [
            "Email Dr. Lee about thesis chapter 2 tomorrow 9am #school !high", "Book campsite sat 4pm #trail-crew !high", "Book campsite on sat at 4",
            "Call Gran tonight", "Pay rent due friday", "Pay rent by the 1st", "Plan trip next week", "Read next month", "Dentist in 3 days at 2:30pm",
            "Renew passport in two weeks", "Taxes Apr 15 2027", "Birthday 20th november", "Ship it 2026-12-01", "Groceries 12/5", "Learn Greek someday",
            "Gym every monday", "Meet Sam at noon", "Reply to Jo this evening !!", "Sat with Gran", "Pi is 3.14 #math", "Call mom today, 5pm",
            "Lunch thursday night", "Clean garage this weekend", "Report day after tomorrow 14:00", "Read Kant anytime #school/thesis",
            "- [ ] Buy fuel !l", "Water plants in a week", "Exam next friday 8 am", "Party on Dec 31st 2026 10pm",
        ]
        let quick = phrases.map { text -> QuickCase in
            // The website reads the whole line through parseLines, which takes off a list's "- [ ] " first.
            let source = text.hasPrefix("- [ ] ") ? String(text.dropFirst(6)) : text
            let line = QuickAddParser.parse(source, now: now, calendar: cal)
            return QuickCase(text: text, title: line.title, when: line.when, evening: line.isEvening, time: line.time.map { "\($0.hour):\($0.minute)" },
                             deadline: line.deadline, tags: line.tags, priority: line.priority.rawValue, place: line.place?.rawValue,
                             pieces: line.pieces.map { "\($0.part.rawValue):\(source[$0.range])" })
        }

        var edits: [EditCase] = []
        let at = Self.made.addingTimeInterval(1000)
        for change in [{ (t: inout TaskItem) in t.title = "Water the boxes" }, { $0.checklist[1].isDone = true }, { $0.when = nil; $0.isEvening = true },
                       { $0.listID = UUID(uuidString: "B0000000-0000-4000-8000-000000000002"); $0.order = 9 }, { $0.reminders.removeAll(); $0.nagging = nil },
                       { $0.completedAt = at }, { $0.notes = $0.notes }] {
            var new = rich
            change(&new)
            var stamped = new
            stamped.noteChanges(from: rich, at: at)
            edits.append(EditCase(old: try Self.json(rich), new: try Self.json(new), at: at.timeIntervalSinceReferenceDate, result: try Self.json(stamped)))
        }

        let out = ModelVectors(note: "Made by TasksWebEditVectorsTests.makeModelVectors from the real Tasks model. Test key only.",
                               rootKey: (0..<32).map { String(format: "%02x", 100 + $0) }.joined(), timeZone: cal.timeZone.identifier,
                               now: now.timeIntervalSinceReferenceDate, tasks: tasks, repeats: repeats, copies: copies, skips: skips, quickAdd: quick, edits: edits)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(out).write(to: Self.docs.appendingPathComponent("tasks-edit-vectors.json"))
    }
}
