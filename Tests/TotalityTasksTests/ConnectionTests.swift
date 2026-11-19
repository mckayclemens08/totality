import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

/// Says a reply came in a conversation, as Mail would.
private struct FakeMail: ReplyWatcher {
    let module = ModuleID.mail
    let kinds: Set<ContentKind> = []
    let answers: [String: Reply]

    func replies(to waiting: [String: Date]) async -> [String: Reply] {
        answers.filter { waiting[$0.key] != nil }
    }
}

/// Step 4 of issue 123: tasks from other modules, waiting for replies, and the Calendar.
@MainActor
@Suite struct ConnectionTests {
    private let conversation = UUID().uuidString

    private func module(_ blobs: MemoryBlobs, key: ContentRootKey) -> (TasksModule, TaskVault) {
        let vault = TaskVault(store: blobs, rootKey: key)
        return (TasksModule(vault: vault, calendar: { denver }, now: { agreed }), vault)
    }

    private func waitingDraft(since: Date = agreed) -> TaskDraft {
        TaskDraft(
            title: "Hear back from Dr. Alvarez about the abstract",
            source: TaskSource(module: .mail, itemID: conversation, title: "Conference abstract", detail: "Dr. Alvarez",
                               waiting: .init(since: since))
        )
    }

    @Test("The registry hands every module the one task maker and planner, and agendas can leave a module out")
    func registryWiring() async throws {
        let (tasks, _) = module(MemoryBlobs(), key: try .generate())
        let registry = try ModuleRegistry(handlers: [tasks])
        #expect(registry.taskMaker?.module == .tasks)
        #expect(registry.planners.map(\.module) == [.tasks])
        let none = try ModuleRegistry(handlers: [])
        #expect(none.taskMaker == nil)

        let made = try await #require(registry.taskMaker).makeTask(TaskDraft(
            title: "Print 12 copies", source: TaskSource(module: .messages, itemID: "!room:usetotality.com", title: "Priya Shah")
        ))
        try await registry.planners[0].plan(made.id.uuidString, at: moment(2026, 11, 15, 16), minutes: 45)
        let all = await registry.agenda(from: moment(2026, 11, 15, 0), to: moment(2026, 11, 16, 0))
        #expect(all.map(\.title) == ["Print 12 copies"])
        #expect(all.first?.module == .tasks)
        #expect(await registry.agenda(from: moment(2026, 11, 15, 0), to: moment(2026, 11, 16, 0), except: .tasks).isEmpty)
    }

    @Test("A task from another module lands in the Inbox with its link and quote, sealed")
    func makeTask() async throws {
        let blobs = MemoryBlobs()
        let (tasks, vault) = module(blobs, key: try .generate())
        let quote = "It is ethical mind qua the substantial will manifest and revealed to itself"
        let made = try await tasks.makeTask(TaskDraft(
            title: "  Quote §258 in paper section 3 ",
            source: TaskSource(module: .reader, itemID: UUID().uuidString, title: "Philosophy of Right", quote: quote)
        ))
        #expect(made.line == "Added “Quote §258 in paper section 3” to Inbox")
        let task = try await vault.task(made.id)
        #expect(task.place == .inbox)
        #expect(task.title == "Quote §258 in paper section 3")
        #expect(task.source?.quote == quote)
        #expect(task.source?.module == .reader)
        // The quote, title and source are inside the seal, never in the stored bytes.
        let stored = String(decoding: blobs.everything, as: UTF8.self)
        #expect(!stored.contains("ethical mind"))
        #expect(!stored.contains("Philosophy of Right"))
    }

    @Test("A blank title falls back to the source's name")
    func blankTitle() {
        let draft = TaskDraft(title: " ", source: TaskSource(module: .web, itemID: "https://plato.stanford.edu", title: "Original Position"))
        #expect(TaskConnections.task(from: draft, order: 1, now: agreed).title == "Original Position")
    }

    @Test("A reply ticks a waiting task off quietly, with Undo, and Undo keeps it waiting")
    func autoComplete() async throws {
        let blobs = MemoryBlobs()
        let key = try ContentRootKey.generate()
        let (tasks, vault) = module(blobs, key: key)
        let made = try await tasks.makeTask(waitingDraft())

        let model = TasksModel(vault: vault, calendar: denver, now: { agreed.addingTimeInterval(3600) })
        model.replyWatchers = [FakeMail(answers: [conversation: Reply(at: agreed.addingTimeInterval(1800), from: "Eli")])]
        await model.load()
        #expect(model.isDone(made.id))
        #expect(model.lastCompleted?.line == "Eli replied, so the task is done")
        let done = try await vault.task(made.id)
        #expect(done.source?.waiting?.repliedAt == agreed.addingTimeInterval(1800))
        #expect(model.waitingList.doneToday.map(\.id) == [made.id])

        await model.undoCompletion()
        #expect(!model.isDone(made.id))
        // The same reply doesn't tick it off again.
        await model.load()
        #expect(!model.isDone(made.id))
        #expect(model.waitingList.open.map(\.id) == [made.id])
    }

    @Test("Replies from before the wait began, or in other conversations, don't count")
    func earlyReplies() throws {
        let draft = waitingDraft()
        let task = TaskConnections.task(from: draft, order: 1, now: agreed)
        let early = [conversation: Reply(at: agreed.addingTimeInterval(-60), from: "Eli")]
        #expect(TaskConnections.answered([task], in: .mail, by: early).isEmpty)
        let elsewhere = [UUID().uuidString: Reply(at: agreed.addingTimeInterval(60), from: "Eli")]
        #expect(TaskConnections.answered([task], in: .mail, by: elsewhere).isEmpty)
        let otherModule = [conversation: Reply(at: agreed.addingTimeInterval(60), from: "Eli")]
        #expect(TaskConnections.answered([task], in: .messages, by: otherModule).isEmpty)
        #expect(TaskConnections.questions(for: [task], in: .mail) == [conversation: agreed])
    }

    @Test("Dropping a task on a time blocks it there, and only timed, open tasks go on the Calendar")
    func planOnCalendar() async throws {
        let (tasks, vault) = module(MemoryBlobs(), key: try .generate())
        var today = TaskItem(title: "Renew library books", place: .anytime, when: day(2026, 11, 15), createdAt: agreed)
        today = try await vault.save(today, over: nil)
        let overdue = try await vault.save(TaskItem(title: "Return the Rawls reader", place: .anytime, when: day(2026, 11, 13), createdAt: agreed), over: nil)
        let unplanned = await tasks.unplanned(on: agreed)
        #expect(Set(unplanned.map(\.title)) == ["Renew library books", "Return the Rawls reader"])
        #expect(await tasks.agenda(from: moment(2026, 11, 15, 0), to: moment(2026, 11, 16, 0)).isEmpty)

        try await tasks.plan(today.id.uuidString, at: moment(2026, 11, 15, 16), minutes: 45)
        let planned = try await vault.task(today.id)
        #expect(planned.time == TaskTime(hour: 16))
        #expect(planned.blockMinutes == 45)
        #expect(planned.edits[TaskItem.Field.schedule.rawValue] == agreed)
        let items = await tasks.agenda(from: moment(2026, 11, 15, 0), to: moment(2026, 11, 16, 0))
        #expect(items.count == 1)
        #expect(items.first?.end == moment(2026, 11, 15, 16, 45))
        #expect(await tasks.unplanned(on: agreed).map(\.id) == [overdue.id.uuidString])
        await #expect(throws: TasksModuleError.notFound) { try await tasks.plan(UUID().uuidString, at: agreed, minutes: 30) }
    }

    @Test("The link merges as its own part, so a link removed on one device and a tick on another both survive")
    func linkMerges() {
        var base = TaskConnections.task(from: waitingDraft(), order: 1, now: agreed)
        base.edits = [:]
        var removed = base
        removed.source = nil
        removed.noteChanges(from: base, at: agreed.addingTimeInterval(10))
        var ticked = base
        ticked.completedAt = agreed.addingTimeInterval(20)
        ticked.noteChanges(from: base, at: agreed.addingTimeInterval(20))
        let merged = removed.merged(with: ticked)
        #expect(merged.source == nil)
        #expect(merged.isCompleted)
        #expect(merged == ticked.merged(with: removed))
    }

    @Test("A task saved before step 4 still opens, with no link")
    func olderTask() throws {
        let old = #"{"id":"\#(UUID().uuidString)","title":"Old","createdAt":0}"#
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(old.utf8))
        #expect(task.source == nil)
        #expect(task.blockMinutes == nil)
    }
}
