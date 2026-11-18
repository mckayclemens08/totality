import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

/// Step 2: areas, projects with headings, smart lists, moving, several at once and undoable delete.
@MainActor
@Suite struct ListsTests {
    private let school = TaskList(name: "School", kind: .area, createdAt: agreed)
    private let debate = TaskList(name: "Debate", kind: .area, createdAt: agreed)

    private func model(_ blobs: MemoryBlobs = MemoryBlobs()) throws -> (TasksModel, TaskVault) {
        let vault = TaskVault(store: blobs, rootKey: try .generate())
        return (TasksModel(vault: vault, calendar: denver, now: { agreed }), vault)
    }

    // MARK: - The model

    @Test("A list saved by step 1 still opens, as an active list with no headings")
    func oldListOpens() throws {
        let json = #"{"id":"6F1D2C2E-8C2B-4B9A-9C55-2D7E3F0A1B11","name":"Thesis","kind":"project","createdAt":0,"updatedAt":0}"#
        let list = try JSONDecoder().decode(TaskList.self, from: Data(json.utf8))
        #expect(list.name == "Thesis")
        #expect(list.headings.isEmpty)
        #expect(list.status == .active)
        #expect(list.rules == nil)
    }

    @Test("A rule kind from a newer version opens, and never matches")
    func unknownRule() throws {
        let json = #"{"id":"6F1D2C2E-8C2B-4B9A-9C55-2D7E3F0A1B12","kind":"fromMail"}"#
        let rule = try JSONDecoder().decode(SmartRule.self, from: Data(json.utf8))
        #expect(rule.kind == .unknown)
        let task = TaskItem(title: "Reply to Dr. Alvarez", notes: "About the outline", createdAt: agreed)
        #expect(!ListRules.matches(task, SmartRules(match: .any, rules: [rule]), lists: [], today: day(2026, 11, 15), in: denver))
    }

    @Test("A project, its headings and every name in it are sealed: none shows in what's stored")
    func projectSealed() async throws {
        let blobs = MemoryBlobs()
        let (model, vault) = try model(blobs)
        await model.load()
        let area = try #require(await model.addList(name: "School", kind: .area))
        let project = try #require(await model.addList(name: "Hegel paper", kind: .project, area: area.id, deadline: day(2026, 11, 21)))
        await model.addHeading("Recognition and labour", to: project.id)
        _ = await model.addList(name: "Due this week", kind: .smart, rules: SmartRules(rules: [SmartRule(kind: .tag, tag: "kojeve")]))
        let stored = String(decoding: blobs.everything, as: UTF8.self)
        for secret in ["School", "Hegel", "Recognition", "Due this week", "kojeve"] {
            #expect(!stored.contains(secret))
        }
        let reopened = try await vault.list(project.id)
        #expect(reopened.headings.map(\.title) == ["Recognition and labour"])
        #expect(reopened.areaID == area.id)
        #expect(reopened.deadline == day(2026, 11, 21))
    }

    @Test("A project's sections: no heading first, then headings in order, done tasks staying in place")
    func sections() async throws {
        let (model, _) = try model()
        await model.load()
        let project = try #require(await model.addList(name: "Hegel paper", kind: .project))
        await model.addHeading("Research", to: project.id)
        await model.addHeading("Drafting", to: project.id)
        let headings = try #require(model.list(project.id)).headings
        let loose = try #require(await model.add("Email Dr. Alvarez the outline", in: .anytime, list: project.id).first)
        let reread = try #require(await model.add("Reread Phenomenology §178–196", in: .anytime, list: project.id, heading: headings[0].id).first)
        _ = await model.add("Pull quotes from Pippin", in: .anytime, list: project.id, heading: headings[0].id)
        _ = await model.add("Outline the argument", in: .anytime, list: project.id, heading: headings[1].id)
        await model.toggle(reread.id)

        let sections = model.sections(of: try #require(model.list(project.id)))
        #expect(sections.map { $0.heading?.title } == [nil, "Research", "Drafting"])
        #expect(sections[0].tasks.map(\.id) == [loose.id])
        #expect(sections[1].tasks.map(\.title) == ["Reread Phenomenology §178–196", "Pull quotes from Pippin"])
        #expect(sections[1].done == 1)
        #expect(model.projectProgress(of: try #require(model.list(project.id))) == ListProgress(done: 1, total: 4))
        #expect(model.nextTask(in: try #require(model.list(project.id)))?.id == loose.id)

        // Removing a heading keeps its tasks in the project, with no heading.
        await model.removeHeading(headings[0].id, from: project.id)
        let after = model.sections(of: try #require(model.list(project.id)))
        #expect(after.map { $0.heading?.title } == [nil, "Drafting"])
        #expect(after[0].tasks.count == 3)
    }

    @Test("An area holds its projects by status and its own loose tasks")
    func area() async throws {
        let (model, _) = try model()
        await model.load()
        let area = try #require(await model.addList(name: "School", kind: .area))
        let hegel = try #require(await model.addList(name: "Hegel paper", kind: .project, area: area.id))
        let thesis = try #require(await model.addList(name: "Thesis, chapter 3", kind: .project, area: area.id))
        await model.changeList(thesis.id) { $0.status = .finished }
        _ = await model.add("Return library books", in: .anytime, list: area.id)
        _ = await model.add("Section 3: objections", in: .anytime, list: hegel.id)
        #expect(model.projects(in: area.id).map(\.name) == ["Hegel paper"])
        #expect(model.projects(in: area.id, status: .finished).map(\.name) == ["Thesis, chapter 3"])
        #expect(model.looseTasks(in: try #require(model.list(area.id))).map(\.title) == ["Return library books"])
    }

    @Test("Moving: to a project takes it out of the Inbox, to Today plans it, to Inbox takes it out of the project")
    func move() async throws {
        let (model, _) = try model()
        await model.load()
        let project = try #require(await model.addList(name: "MUN conference prep", kind: .project))
        let task = try #require(await model.add("Draft position paper on water rights", in: .inbox).first)
        await model.move([task.id], to: .list(project.id))
        var moved = try #require(model.tasks.first { $0.id == task.id })
        #expect(moved.listID == project.id)
        #expect(moved.place == .anytime)
        await model.move([task.id], to: .bucket(.today))
        moved = try #require(model.tasks.first { $0.id == task.id })
        #expect(moved.when == model.today)
        #expect(moved.listID == project.id)
        await model.move([task.id], to: .bucket(.inbox))
        moved = try #require(model.tasks.first { $0.id == task.id })
        #expect(moved.listID == nil && moved.when == nil && moved.place == .inbox)
    }

    @Test("A dragged task lands just above the one it's dropped on, under that task's heading")
    func place() async throws {
        let (model, _) = try model()
        await model.load()
        let project = try #require(await model.addList(name: "Hegel paper", kind: .project))
        await model.addHeading("Drafting", to: project.id)
        let heading = try #require(model.list(project.id)?.headings.first)
        let a = try #require(await model.add("Outline the argument", in: .anytime, list: project.id, heading: heading.id).first)
        let b = try #require(await model.add("Section 2: recognition and labour", in: .anytime, list: project.id, heading: heading.id).first)
        let c = try #require(await model.add("Read aloud, cut 300 words", in: .anytime, list: project.id).first)
        let shown = model.sections(of: try #require(model.list(project.id))).flatMap(\.tasks)
        await model.place(c.id, before: b.id, in: shown)
        let after = model.sections(of: try #require(model.list(project.id)))
        #expect(after.map { $0.heading?.title } == ["Drafting"])
        #expect(after[0].tasks.map(\.id) == [a.id, c.id, b.id])
    }

    @Test("Several at once: complete, plan and tag")
    func severalAtOnce() async throws {
        let (model, _) = try model()
        await model.load()
        let added = await model.add("Ask Priya for Kant notes\nBuy chalk and a new belay device\nCheck Hidden Valley campground", in: .anytime)
        let ids = Set(added.prefix(2).map(\.id))
        await model.addTag("#errands", to: ids)
        #expect(model.tasks.filter { ids.contains($0.id) }.map(\.tags) == [["errands"], ["errands"]])
        await model.addTag("Errands", to: ids)
        #expect(model.tasks.filter { ids.contains($0.id) }.map(\.tags) == [["errands"], ["errands"]])
        await model.schedule(ids, .day(model.today, evening: false))
        #expect(Set(model.tasks(in: .today).map(\.id)) == ids)
        await model.complete(ids)
        let allDone = ids.allSatisfy { model.isDone($0) }
        #expect(allDone)
        #expect(!model.isDone(added[2].id))
    }

    // MARK: - Smart lists

    private func task(_ title: String, tags: [String] = [], list: UUID? = nil, priority: TaskItem.Priority = .none,
                      when: TaskDay? = nil, deadline: TaskDay? = nil, notes: String = "") -> TaskItem {
        TaskItem(title: title, notes: notes, when: when, deadline: deadline, tags: tags, priority: priority, listID: list, createdAt: agreed)
    }

    @Test("Match all needs every rule; match any needs one")
    func allAndAny() {
        let hegel = TaskList(name: "Hegel paper", kind: .project, areaID: school.id, createdAt: agreed)
        let lists = [school, debate, hegel]
        let today = day(2026, 11, 15)
        let objections = task("Section 3: objections", list: hegel.id, deadline: day(2026, 11, 20))
        let register = task("Register for spring seminars", list: school.id, deadline: day(2026, 12, 1))
        let water = task("Draft position paper on water rights", tags: ["someday"], list: debate.id, deadline: day(2026, 11, 17))
        let all = [objections, register, water]
        let rules = [
            SmartRule(kind: .area, listID: school.id),
            SmartRule(kind: .deadline, days: 7),
            SmartRule(kind: .tag, isNegated: true, tag: "Someday"),
        ]
        let matchAll = ListRules.tasks(matching: SmartRules(match: .all, rules: rules), from: all, lists: lists, today: today, in: denver)
        #expect(matchAll.map(\.title) == ["Section 3: objections"])
        let matchAny = ListRules.tasks(matching: SmartRules(match: .any, rules: rules), from: all, lists: lists, today: today, in: denver)
        // Soonest deadline first.
        #expect(matchAny.map(\.title) == ["Draft position paper on water rights", "Section 3: objections", "Register for spring seminars"])
    }

    @Test("Each kind of rule", arguments: [
        (SmartRule(kind: .tag, tag: "school"), true),
        (SmartRule(kind: .tag, tag: "#School"), true),
        (SmartRule(kind: .tag, tag: "thesis"), false),
        (SmartRule(kind: .tag, isNegated: true, tag: "thesis"), true),
        (SmartRule(kind: .priority, priority: .high), true),
        (SmartRule(kind: .priority, priority: .low), false),
        (SmartRule(kind: .when, days: 0), true),
        (SmartRule(kind: .deadline, days: 3), false),
        (SmartRule(kind: .deadline, days: 5), true),
        (SmartRule(kind: .deadline), true),
        (SmartRule(kind: .hasNote), true),
        (SmartRule(kind: .hasNote, isNegated: true), false),
        (SmartRule(kind: .tag), false),
    ])
    func eachRule(rule: SmartRule, expected: Bool) {
        // Tagged "school/thesis", so "school" finds it as a nested tag and "thesis" alone doesn't.
        let item = task(
            "Summarise Brandom on normativity", tags: ["school/thesis"], priority: .high, when: day(2026, 11, 14),
            deadline: day(2026, 11, 20), notes: "Chapter 4 of Reason in Philosophy"
        )
        #expect(ListRules.matches(item, rule, lists: [], today: day(2026, 11, 15), in: denver) == expected)
    }

    @Test("A project rule finds its own tasks; an area rule finds them through their project")
    func listRules() {
        let hegel = TaskList(name: "Hegel paper", kind: .project, areaID: school.id, createdAt: agreed)
        let lists = [school, hegel]
        let quotes = task("Pull quotes from Pippin", list: hegel.id)
        let books = task("Return library books", list: school.id)
        let today = day(2026, 11, 15)
        #expect(ListRules.matches(quotes, SmartRule(kind: .project, listID: hegel.id), lists: lists, today: today, in: denver))
        #expect(!ListRules.matches(books, SmartRule(kind: .project, listID: hegel.id), lists: lists, today: today, in: denver))
        #expect(ListRules.matches(quotes, SmartRule(kind: .area, listID: school.id), lists: lists, today: today, in: denver))
        #expect(ListRules.matches(books, SmartRule(kind: .area, listID: school.id), lists: lists, today: today, in: denver))
    }

    @Test("A smart list with no rules finds nothing, and finished tasks never show")
    func emptyAndDone() {
        var done = task("Outline the argument", tags: ["school"])
        done.completedAt = agreed
        let today = day(2026, 11, 15)
        #expect(ListRules.tasks(matching: SmartRules(), from: [task("Call Dad")], lists: [], today: today, in: denver).isEmpty)
        #expect(ListRules.tasks(matching: SmartRules(rules: [SmartRule(kind: .tag, tag: "school")]), from: [done], lists: [], today: today, in: denver).isEmpty)
    }

    // MARK: - Undoable delete

    @Test("Delete hides at once; Undo brings everything back and nothing was removed from the device")
    func deleteUndo() async throws {
        let (model, vault) = try model()
        model.deleteUndoTime = .seconds(60)
        await model.load()
        let added = await model.add("Pull quotes from Pippin\nAsk Priya for Kant notes\nBuy chalk", in: .anytime)
        let ids = Set(added.prefix(2).map(\.id))
        await model.delete(tasks: ids)
        #expect(model.pendingDelete?.title == "2 tasks deleted")
        #expect(model.tasks.map(\.title) == ["Buy chalk"])
        #expect(try await vault.everything().tasks.count == 3)
        // A refresh meanwhile doesn't bring them back on screen.
        await model.load()
        #expect(model.tasks.map(\.title) == ["Buy chalk"])
        model.undoDelete()
        #expect(model.pendingDelete == nil)
        #expect(Set(model.tasks.map(\.id)) == Set(added.map(\.id)))
        await model.finishPendingDelete()
        #expect(try await vault.everything().tasks.count == 3)
    }

    @Test("When Undo's time runs out, the delete is for good")
    func deleteForGood() async throws {
        let (model, vault) = try model()
        model.deleteUndoTime = .milliseconds(50)
        await model.load()
        let added = await model.add("Ask Sam about the rope\nCheck Hidden Valley campground", in: .anytime)
        await model.delete(tasks: [added[0].id])
        for _ in 0..<100 where model.pendingDelete != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.pendingDelete == nil)
        #expect(try await vault.everything().tasks.map(\.title) == ["Check Hidden Valley campground"])
        #expect(try await vault.deletedObjectIDs().contains(added[0].id))
    }

    @Test("A second delete makes the first permanent; deleting an area takes its projects and tasks")
    func deleteArea() async throws {
        let (model, vault) = try model()
        model.deleteUndoTime = .seconds(60)
        await model.load()
        let stray = try #require(await model.add("Call Dad", in: .anytime).first)
        await model.delete(tasks: [stray.id])
        let area = try #require(await model.addList(name: "Outdoors", kind: .area))
        let trip = try #require(await model.addList(name: "Climbing trip, Joshua Tree", kind: .project, area: area.id))
        _ = await model.add("Book campsite for Saturday", in: .anytime, list: trip.id)
        _ = await model.add("Wax the skis", in: .anytime, list: area.id)
        let kept = try #require(await model.add("Return library books", in: .anytime).first)
        await model.delete(tasks: [], lists: [area.id])
        // The first delete went through when the second began.
        #expect(try await !vault.everything().tasks.contains { $0.id == stray.id })
        #expect(model.pendingDelete?.title == "“Outdoors” deleted")
        #expect(model.lists.isEmpty)
        #expect(model.tasks.map(\.id) == [kept.id])
        await model.finishPendingDelete()
        let left = try await vault.everything()
        #expect(left.lists.isEmpty)
        #expect(left.tasks.map(\.id) == [kept.id])
    }
}
