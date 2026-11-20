import Foundation
import Testing
import TotalityCore
@testable import TotalityTasks

/// Step 6: shared lists, roles, assigning, comments and leaving.
@MainActor
@Suite struct SharingTests {
    let server = FakeServer()

    private func project() -> (TaskList, [TaskItem]) {
        let heading = TaskList.Heading(title: "This week")
        let list = TaskList(name: "Wittgenstein reading group", kind: .project, areaID: UUID(), headings: [heading], createdAt: agreed)
        var read = TaskItem(title: "Read Investigations §§243–315", place: .anytime, listID: list.id, headingID: heading.id, order: 1, createdAt: agreed)
        read.reminders = [TaskReminder(kind: .at(day(2026, 11, 19), TaskTime(hour: 9)!))]
        let handout = TaskItem(title: "Bring the Kripke handout", place: .anytime, listID: list.id, headingID: heading.id, order: 2, createdAt: agreed)
        let elsewhere = TaskItem(title: "Return library books", createdAt: agreed)
        return (list, [read, handout, elsewhere])
    }

    /// Me shares the reading group with Priya (edit) and Maya (view); both accept.
    private func shared() async throws -> (room: String, me: SharedListsModel, priya: SharedListsModel, maya: SharedListsModel) {
        let me = SharedListsModel(rooms: server.device(for: "mckay"), now: { agreed.addingTimeInterval(30) })
        let priya = SharedListsModel(rooms: server.device(for: "priya"), now: { agreed.addingTimeInterval(60) })
        let maya = SharedListsModel(rooms: server.device(for: "mayat"), now: { agreed.addingTimeInterval(120) })
        await me.refresh()
        let (list, tasks) = project()
        let room = try #require(await me.share(list, tasks: tasks, with: ["priya": .editor, "mayat": .viewer]))
        for model in [priya, maya] {
            await model.refresh()
            let invite = try #require(model.invites.first)
            await model.accept(invite)
            await model.refresh()
        }
        await me.refresh()
        return (room, me, priya, maya)
    }

    @Test("Signing in as someone else on the same phone drops the last account's shared lists")
    func anotherAccountOnTheSamePhone() async throws {
        let rooms = server.device(for: "mckay")
        _ = server.device(for: "priya")
        let phone = SharedListsModel(rooms: rooms, now: { agreed })
        await phone.refresh()
        let (list, tasks) = project()
        _ = try #require(await phone.share(list, tasks: tasks, with: ["priya": .editor]))
        await phone.refresh()
        #expect(phone.lists.count == 1)
        rooms.me = "applereview2"
        server.failNextRooms = true
        await phone.refresh()
        #expect(phone.own == "applereview2")
        #expect(phone.lists.isEmpty, "even when the new account's rooms can't be read yet")
    }

    @Test("Sharing puts the list and only its tasks in the room, without area, reminders or snoozes")
    func share() async throws {
        let (room, me, _, _) = try await shared()
        let state = try #require(me.list(room))
        #expect(state.displayName == "Wittgenstein reading group")
        #expect(state.list?.areaID == nil)
        #expect(state.liveTasks.map(\.task.title) == ["Read Investigations §§243–315", "Bring the Kripke handout"])
        #expect(state.liveTasks.allSatisfy { $0.task.reminders.isEmpty })
        #expect(state.isEncrypted)
        #expect(state.member("mckay")?.role == .owner)
        #expect(state.member("priya")?.role == .editor)
        #expect(state.member("mayat")?.role == .viewer)
    }

    @Test("Smart lists can't be shared")
    func noSmart() async {
        let me = SharedListsModel(rooms: server.device(for: "mckay"))
        let smart = TaskList(name: "Due soon", kind: .smart, createdAt: agreed)
        #expect(await me.share(smart, tasks: [], with: [:]) == nil)
        #expect(server.rooms.isEmpty)
    }

    @Test("An editor's tick reaches everyone; a viewer's edit is dropped by every device, but their comment counts")
    func roles() async throws {
        let (room, me, priya, maya) = try await shared()
        let handout = try #require(me.list(room)?.liveTasks.first { $0.task.title.hasPrefix("Bring") })
        await priya.toggle(handout.id, in: room)
        await me.refresh()
        #expect(me.list(room)?.tasks[handout.id]?.task.isCompleted == true)

        // Maya's screen won't send it; a modified app that sends it anyway is ignored by every device.
        #expect(await maya.change(handout.id, in: room) { $0.title = "Hijacked" } == false)
        var forged = try #require(maya.list(room)?.tasks[handout.id]?.task)
        forged.title = "Hijacked"
        forged.edits["title"] = agreed.addingTimeInterval(9999)
        try await server.device(for: "mayat").post(try SharedPost(kind: .task, task: forged).encoded(), to: room)
        await me.refresh()
        #expect(me.list(room)?.tasks[handout.id]?.task.title == "Bring the Kripke handout")
        #expect(me.list(room)?.refused == 1)

        #expect(await maya.comment("Is it the 1982 edition?", on: handout.id, in: room))
        await me.refresh()
        #expect(me.list(room)?.comments(on: handout.id).map(\.author) == ["mayat"])
    }

    @Test("A post's author is who the room says sent it, never a name written in the post")
    func authorFromRoom() async throws {
        let (room, me, priya, _) = try await shared()
        let task = try #require(me.list(room)?.liveTasks.first)
        await priya.comment("Yes, 1982.", on: task.id, in: room)
        await me.refresh()
        let comment = try #require(me.list(room)?.comments(on: task.id).first as SharedComment?)
        #expect(comment.author == "priya")
    }

    @Test("Only editors can be given a task, and an assignment shows in their own Tasks")
    func assigning() async throws {
        let (room, me, priya, maya) = try await shared()
        let task = try #require(me.list(room)?.liveTasks.first)
        await me.assign(task.id, in: room, to: "mayat")
        #expect(me.notice != nil)
        await me.assign(task.id, in: room, to: "priya")
        await priya.refresh()
        #expect(priya.assignedToMe.map(\.task.id) == [task.id])
        #expect(priya.list(room)?.tasks[task.id]?.assignedBy == "mckay")
        await maya.refresh()
        #expect(maya.assignedToMe.isEmpty)
        #expect(server.sentMessages.isEmpty, "Message them is off by default")
    }

    @Test("A forged assignment to a viewer is ignored")
    func forgedAssignment() async throws {
        let (room, me, _, _) = try await shared()
        let task = try #require(me.list(room)?.liveTasks.first)
        let post = SharedPost(kind: .task, task: task.task, assignment: .init(username: "mayat", at: agreed.addingTimeInterval(500)))
        try await server.device(for: "priya").post(try post.encoded(), to: room)
        await me.refresh()
        #expect(me.list(room)?.tasks[task.id]?.assignee == nil)
    }

    @Test("Message them about it sends one chat line only when chosen")
    func messageThem() async throws {
        let (room, me, _, _) = try await shared()
        let task = try #require(me.list(room)?.liveTasks.first)
        await me.assign(task.id, in: room, to: "priya", messageThem: true)
        #expect(server.sentMessages.count == 1)
        #expect(server.sentMessages.first?.to == "priya")
    }

    @Test("Two editors change different parts at once and both changes survive")
    func conflict() async throws {
        let (room, me, priya, _) = try await shared()
        let task = try #require(me.list(room)?.liveTasks.first)
        // Both work from the same version, then post.
        await me.change(task.id, in: room) { $0.title = "Read §§243–315 closely" }
        await priya.toggle(task.id, in: room)
        await me.refresh()
        await priya.refresh()
        let mine = try #require(me.list(room)?.tasks[task.id]?.task)
        let hers = try #require(priya.list(room)?.tasks[task.id]?.task)
        #expect(mine.title == "Read §§243–315 closely")
        #expect(mine.isCompleted)
        #expect(mine == hers)
    }

    @Test("Removed wins over a later edit")
    func removeWins() async throws {
        let (room, me, priya, _) = try await shared()
        let task = try #require(me.list(room)?.liveTasks.first)
        let stale = task.task
        await me.remove(task: task.id, from: room)
        var edit = stale
        edit.title = "Edited after"
        edit.noteChanges(from: stale, at: agreed.addingTimeInterval(9999))
        try await server.device(for: "priya").post(try SharedPost(kind: .task, task: edit).encoded(), to: room)
        await priya.refresh()
        #expect(priya.list(room)?.liveTasks.contains { $0.id == task.id } == false)
    }

    @Test("Someone removed loses their assignments, and the owner must hand over before leaving")
    func removeAndLeave() async throws {
        let (room, me, priya, _) = try await shared()
        let task = try #require(me.list(room)?.liveTasks.first)
        await me.assign(task.id, in: room, to: "priya")
        await me.remove("priya", from: room)
        #expect(me.list(room)?.assignee(of: try #require(me.list(room)?.tasks[task.id])) == nil)
        await priya.refresh()
        #expect(priya.list(room) == nil)

        #expect(await me.leave(room) == false)
        #expect(me.notice?.contains("owner first") == true)
    }

    @Test("Handing over: the new owner can manage people, the old one is an editor and leaves")
    func handOver() async throws {
        let (room, me, priya, maya) = try await shared()
        #expect(await me.handOverAndLeave(room, to: "mayat") == false, "A viewer can't become the owner")
        #expect(await me.handOverAndLeave(room, to: "priya"))
        await priya.refresh()
        #expect(priya.list(room)?.owner?.username == "priya")
        #expect(priya.list(room)?.member("mckay") == nil)
        await priya.setRole(.editor, for: "mayat", in: room)
        await maya.refresh()
        #expect(maya.canEdit(room))
        // Tasks made while mckay could edit still stand after they left.
        #expect(priya.list(room)?.liveTasks.count == 2)
    }

    @Test("Only the owner can delete for everyone, and it leaves everyone's Tasks")
    func deleteForEveryone() async throws {
        let (room, me, priya, _) = try await shared()
        #expect(await priya.deleteForEveryone(room) == false)
        #expect(await me.deleteForEveryone(room))
        await priya.refresh()
        #expect(priya.lists.isEmpty)
    }

    @Test("Declining is quiet and leaves no trace for the inviter")
    func declineQuietly() async throws {
        let me = SharedListsModel(rooms: server.device(for: "mckay"))
        let eli = SharedListsModel(rooms: server.device(for: "eli.park"))
        await me.refresh()
        let (list, tasks) = project()
        let room = try #require(await me.share(list, tasks: tasks, with: ["eli.park": .editor]))
        await eli.refresh()
        await eli.decline(try #require(eli.invites.first))
        #expect(eli.invites.isEmpty)
        #expect(server.sentMessages.isEmpty)
        #expect(server.rooms[room]?.events.contains { if case .post(_, "eli.park", _, _) = $0 { true } else { false } } == false)
    }

    @Test("A room that isn't encrypted is left, never shown")
    func unencrypted() async throws {
        let (room, me, _, _) = try await shared()
        server.rooms[room]?.isEncrypted = false
        await me.refresh()
        #expect(me.lists.isEmpty)
        #expect(server.rooms[room]?.joined.contains("mckay") == false)
    }

    @Test("Handles are taken as typed, with @ and server dropped")
    func handles() {
        #expect(SharedListsModel.handle(" @Eli.Park ") == "eli.park")
        #expect(SharedListsModel.handle("@priya:usetotality.com") == "priya")
    }

    @Test("Roles round down from power levels")
    func powerLevels() {
        #expect(SharedRole(powerLevel: 100) == .owner)
        #expect(SharedRole(powerLevel: 75) == .editor)
        #expect(SharedRole(powerLevel: 49) == .viewer)
        #expect(!SharedRole.viewer.canEdit)
    }

    @Test("Posts from a newer version, or not posts at all, are skipped")
    func unknownPosts() {
        #expect(SharedPost.decode("hello") == nil)
        #expect(SharedPost.decode(#"{"v":1,"kind":"poll"}"#) == nil)
    }
}

/// Step 6's cases for the brief §6 two-user test. The ones above run against a stand-in server; these
/// cover what the issue lists for user 2.
@MainActor
@Suite struct SharingTwoUserTests {
    let server = FakeServer()

    @Test("Two-user: user 2 can't see user 1's private lists, only what was shared with them")
    func privateStaysPrivate() async throws {
        let one = SharedListsModel(rooms: server.device(for: "userone"))
        let two = SharedListsModel(rooms: server.device(for: "usertwo"))
        await one.refresh()
        let shared = TaskList(name: "Red Rock climbing trip", kind: .project, createdAt: agreed)
        let room = try #require(await one.share(shared, tasks: [], with: [:]))
        await two.refresh()
        #expect(two.lists.isEmpty)
        #expect(two.invites.isEmpty)
        await #expect(throws: SharedRoomError.self) { try await server.device(for: "usertwo").history(of: room) }
        // A private list never reaches the server at all: it lives in user 1's sealed vault.
        #expect(server.rooms.count == 1)
    }

    @Test("Two-user: user 2 accepts an invite, sees an assigned task and comments on it")
    func inviteAssignComment() async throws {
        let one = SharedListsModel(rooms: server.device(for: "userone"), now: { agreed })
        let two = SharedListsModel(rooms: server.device(for: "usertwo"), now: { agreed.addingTimeInterval(60) })
        await one.refresh()
        let list = TaskList(name: "Red Rock climbing trip", kind: .project, createdAt: agreed)
        let rack = TaskItem(title: "Pack the rack and both 60 m ropes", listID: list.id, createdAt: agreed)
        let room = try #require(await one.share(list, tasks: [rack], with: ["usertwo": .editor]))
        await two.refresh()
        await two.accept(try #require(two.invites.first))
        await one.refresh()
        await one.assign(rack.id, in: room, to: "usertwo")
        await two.refresh()
        #expect(two.assignedToMe.map(\.task.task.title) == ["Pack the rack and both 60 m ropes"])
        #expect(await two.comment("Got both ropes.", on: rack.id, in: room))
        await one.refresh()
        #expect(one.list(room)?.comments(on: rack.id).map(\.text) == ["Got both ropes."])
    }

    @Test("Two-user live: two real accounts on two iPhones", .disabled("Waits for the owner's friend's account. Steps: docs/module-contracts.md, Tasks sharing, live two-user run."))
    func live() {}
}
