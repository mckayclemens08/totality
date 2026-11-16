import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

@MainActor
@Suite struct TasksModelTests {
    private func model(_ blobs: MemoryBlobs = MemoryBlobs(), key: ContentRootKey? = nil) throws -> (TasksModel, TaskVault) {
        let vault = TaskVault(store: blobs, rootKey: try key ?? .generate())
        return (TasksModel(vault: vault, calendar: denver, now: { agreed }), vault)
    }

    @Test("Quick add reads the line and puts the task where it belongs")
    func add() async throws {
        let (model, _) = try model()
        await model.load()
        let added = await model.add("Outline thesis chapter 3 tomorrow #thesis", in: .inbox)
        #expect(added.count == 1)
        #expect(model.tasks(in: .upcoming).map(\.title) == ["Outline thesis chapter 3"])
        #expect(added[0].place == .anytime)
        #expect(added[0].tags == ["thesis"])
        await model.add("Capture a conlang idea", in: .inbox)
        #expect(model.tasks(in: .inbox).map(\.title) == ["Capture a conlang idea"])
        await model.add("Call Gran", in: .today)
        #expect(model.tasks(in: .today).map(\.title) == ["Call Gran"])
        await model.add("Learn Toki Pona", in: .someday)
        #expect(model.tasks(in: .someday).map(\.title) == ["Learn Toki Pona"])
        await model.add("Book MUN hotel\nPack the placard\n", in: .anytime)
        #expect(model.count(.anytime) == 2)
    }

    @Test("Completing stays ticked in place a moment, then goes to the Logbook, and Undo brings it back")
    func completeAndUndo() async throws {
        let (model, vault) = try model()
        await model.load()
        let task = try #require(await model.add("Submit MUN position paper", in: .today).first)
        await model.toggle(task.id)
        #expect(model.isDone(task.id))
        #expect(model.lastCompleted?.title == "Submit MUN position paper")
        #expect(model.tasks(in: .today).map(\.id) == [task.id])
        #expect(model.count(.today) == 0)
        #expect(model.logbook().first?.tasks.map(\.id) == [task.id])
        #expect(model.completions == 1)
        await model.undoCompletion()
        #expect(!model.isDone(task.id))
        #expect(model.lastCompleted == nil)
        #expect(try await vault.task(task.id).completedAt == nil)
    }

    @Test("A completed task comes back from the Logbook by ticking it again")
    func restore() async throws {
        let (model, _) = try model()
        await model.load()
        let task = try #require(await model.add("Outline chapter 2", in: .anytime).first)
        await model.toggle(task.id)
        model.dismissUndo()
        #expect(model.tasks(in: .anytime).isEmpty)
        await model.toggle(task.id)
        #expect(model.tasks(in: .anytime).map(\.id) == [task.id])
    }

    @Test("Scheduling moves a task between Today, Someday and Anytime")
    func schedule() async throws {
        let (model, _) = try model()
        await model.load()
        let task = try #require(await model.add("Write conlang grammar sketch", in: .inbox).first)
        await model.schedule(task.id, .day(model.today, evening: true))
        #expect(model.tasks(in: .today).first?.isEvening == true)
        await model.schedule(task.id, .someday)
        #expect(model.tasks(in: .someday).map(\.id) == [task.id])
        await model.schedule(task.id, .anytime)
        #expect(model.tasks(in: .anytime).map(\.id) == [task.id])
    }

    @Test("The glance shows Today's tasks, then what's overdue and due next")
    func glance() async throws {
        let (model, _) = try model()
        #expect(model.glance == nil)
        await model.load()
        #expect(model.glance == ModuleGlance(lines: ["Nothing planned today"], isQuiet: true))
        await model.add("Read Hayes chapter 4 today", in: .inbox)
        await model.add("Thesis draft due Wednesday", in: .anytime)
        let task = try #require(await model.add("Reading response", in: .anytime).first)
        await model.change(task.id) { $0.deadline = day(2026, 11, 13) }
        let lines = try #require(model.glance?.lines)
        #expect(lines.first == "Read Hayes chapter 4")
        #expect(lines.contains("1 overdue"))
        #expect(lines.contains("Thesis draft · due Wednesday"))
    }

    @Test("Upcoming shows the calendar's events, which come in through the registry")
    func agenda() async throws {
        let (model, _) = try model()
        let lecture = AgendaItem(
            id: "lecture", title: "Phonology lecture", start: moment(2026, 11, 17, 9), end: moment(2026, 11, 17, 10), isAllDay: false
        )
        model.agenda = { from, to in [lecture].filter { $0.touches(from: from, to: to) } }
        await model.load()
        #expect(model.upcoming.first { $0.day == day(2026, 11, 17) }?.events == [lecture])
    }

    @Test("A vault that can't be read shows the error state, not an empty list")
    func failed() async throws {
        let model = TasksModel(vault: nil, calendar: denver, now: { agreed })
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.glance == nil)
    }

    @Test("Home search finds tasks by their notes, checklist and tags, done ones too")
    func search() async throws {
        let blobs = MemoryBlobs()
        let key = try ContentRootKey.generate()
        let (model, vault) = try model(blobs, key: key)
        await model.load()
        let task = try #require(await model.add("Pack for MUN #mun", in: .anytime).first)
        await model.change(task.id) { $0.checklist = [.init(title: "Country placard"), .init(title: "Blazer")] }
        let done = try #require(await model.add("Email Dr. Lee", in: .anytime).first)
        await model.change(done.id) { $0.notes = "Ask about the phonotactics corpus." }
        await model.toggle(done.id)
        let module = TasksModule(vault: vault, calendar: { denver }, now: { agreed })
        let byChecklist = try await module.search("placard")
        #expect(byChecklist.map(\.title) == ["Pack for MUN"])
        #expect(byChecklist.first?.snippet == "Country placard")
        #expect(byChecklist.first?.module == .tasks)
        #expect(byChecklist.first?.itemID == task.id.uuidString)
        #expect(try await module.search("corpus").first?.detail?.hasPrefix("Logbook") == true)
        #expect(try await module.search("#mun").count == 1)
        #expect(try await module.search("  ").isEmpty)
    }

    @Test("Tasks registers its kinds, and its search and refresh, with the registry")
    func registry() throws {
        let registry = try ModuleRegistry(handlers: [TasksModule(vault: nil)])
        let ref = ContentRef(module: .tasks, kind: .task, id: UUID(), keyRef: .crk(objectID: UUID()), preview: .init(title: "x"))
        #expect(registry.handler(for: ref)?.module == .tasks)
        #expect(registry.searchers.map(\.module) == [.tasks])
        #expect(registry.refreshers.map(\.module) == [.tasks])
        #expect(registry.agendas.isEmpty)
    }
}
