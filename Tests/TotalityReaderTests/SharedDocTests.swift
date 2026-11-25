import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

@Suite("Shared docs: blocks")
struct DocBlocksTests {
    @Test func splitsOnBlankLinesAndKeepsFencesWhole() {
        let text = "# Moab\n\nLeave Friday.\nGas in Green River.\n\n\n```\ncode\n\nmore\n```\n\nEnd."
        #expect(DocBlocks.split(text) == ["# Moab", "Leave Friday.\nGas in Green River.", "```\ncode\n\nmore\n```", "End."])
        #expect(DocBlocks.split(DocBlocks.join(DocBlocks.split(text))) == DocBlocks.split(text))
    }

    private func blocks(_ texts: [String]) -> [SharedBlock] {
        texts.enumerated().map { SharedBlock(order: Double($0.offset + 1), text: $0.element) }
    }

    @Test func untouchedParagraphsAreNotPosted() {
        let base = blocks(["A", "B", "C"])
        let current = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let changes = DocBlocks.changes(from: base, to: "A\n\nB changed\n\nC", current: current)
        #expect(changes.count == 1)
        #expect(changes[0].id == base[1].id)
        #expect(changes[0].text == "B changed")
        #expect(changes[0].rev == 2)
    }

    @Test func insertsGoBetweenTheirNeighbours() {
        let base = blocks(["A", "C"])
        let current = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let changes = DocBlocks.changes(from: base, to: "Z\n\nA\n\nB\n\nC\n\nD", current: current)
        #expect(changes.count == 3)
        var state = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        for change in changes { state[change.id] = change }
        let ordered = state.values.filter { !$0.deleted }.sorted { $0.order < $1.order }.map(\.text)
        #expect(ordered == ["Z", "A", "B", "C", "D"])
    }

    @Test func deletingLeavesATombstone() {
        let base = blocks(["A", "B", "C"])
        let current = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let changes = DocBlocks.changes(from: base, to: "A\n\nC", current: current)
        #expect(changes.count == 1)
        #expect(changes[0].id == base[1].id && changes[0].deleted)
    }

    @Test func aBigDocSplitsIntoPostsUnderTheLimit() throws {
        let paragraph = String(repeating: "word ", count: 2_000)
        let many = blocks(Array(repeating: paragraph, count: 30))
        let posts = try #require(try SharedDocPost.chunked(many, first: SharedDocPost(kind: .doc, docID: UUID(), title: "T", titleRev: 1), rest: .blocks))
        #expect(posts.count > 1)
        #expect(posts.allSatisfy { $0.utf8.count <= SharedDocPost.byteLimit })
        #expect(posts.compactMap(SharedDocPost.decode).flatMap { $0.blocks ?? [] }.count == 30)
    }

    @Test func oneHugeParagraphIsRefused() throws {
        let huge = blocks([String(repeating: "x", count: SharedDocPost.byteLimit + 10)])
        #expect(try SharedDocPost.chunked(huge, first: SharedDocPost(kind: .doc, docID: UUID()), rest: .blocks) == nil)
    }
}

@MainActor
@Suite("Shared docs: two users")
struct SharedDocTwoUserTests {
    let server = FakeServer()

    private func pair() async -> (owner: SharedDocsModel, friend: SharedDocsModel, room: String) {
        let owner = SharedDocsModel(rooms: server.device(for: "mckay"))
        let friend = SharedDocsModel(rooms: server.device(for: "jonah"))
        await owner.refresh()
        await friend.refresh()
        let room = await owner.share(title: "Moab trip plan", text: "Leave Friday.\n\nArches Saturday.", with: ["jonah": .editor])!
        await friend.refresh()
        await friend.accept(friend.invites[0])
        return (owner, friend, room)
    }

    @Test func aSharedDocReachesTheFriend() async throws {
        let (_, friend, room) = await pair()
        let doc = try #require(friend.doc(room))
        #expect(doc.title == "Moab trip plan")
        #expect(doc.text == "Leave Friday.\n\nArches Saturday.")
        #expect(friend.canEdit(room))
    }

    @Test func editsToDifferentParagraphsBothStand() async throws {
        let (owner, friend, room) = await pair()
        await owner.reload(room)
        let ownerBase = owner.doc(room)!.visibleBlocks
        let friendBase = friend.doc(room)!.visibleBlocks
        // Both edit from the same copy, without seeing each other's change.
        _ = await owner.save(room, base: ownerBase, text: "Leave Friday at 3.\n\nArches Saturday.")
        _ = await friend.save(room, base: friendBase, text: "Leave Friday.\n\nArches Saturday, then Fiery Furnace.")
        await owner.reload(room)
        #expect(owner.doc(room)?.text == "Leave Friday at 3.\n\nArches Saturday, then Fiery Furnace.")
    }

    @Test func theSameParagraphGoesToTheLaterWriter() async throws {
        let (owner, friend, room) = await pair()
        await owner.reload(room)
        let ownerBase = owner.doc(room)!.visibleBlocks
        let friendBase = friend.doc(room)!.visibleBlocks
        _ = await owner.save(room, base: ownerBase, text: "Leave Thursday.\n\nArches Saturday.")
        _ = await friend.save(room, base: friendBase, text: "Leave Sunday.\n\nArches Saturday.")
        await owner.reload(room)
        #expect(owner.doc(room)?.text == "Leave Sunday.\n\nArches Saturday.")
    }

    @Test func aViewersEditIsDroppedByEveryDevice() async throws {
        let owner = SharedDocsModel(rooms: server.device(for: "mckay"))
        let viewerRooms = server.device(for: "eli")
        let viewer = SharedDocsModel(rooms: viewerRooms)
        await owner.refresh()
        let room = await owner.share(title: "Plan", text: "One", with: ["eli": .viewer])!
        await viewer.refresh()
        await viewer.accept(viewer.invites[0])
        #expect(!viewer.canEdit(room))
        #expect(await viewer.save(room, base: viewer.doc(room)!.visibleBlocks, text: "Hacked") == nil)
        // Even sent straight to the room, which the server allows, it doesn't count.
        let forged = SharedDocPost(kind: .blocks, docID: viewer.doc(room)!.docID, blocks: [SharedBlock(id: viewer.doc(room)!.visibleBlocks[0].id, order: 1, text: "Hacked", rev: 99)])
        try await viewerRooms.post(try forged.encoded(), to: room)
        await owner.reload(room)
        #expect(owner.doc(room)?.text == "One")
        #expect(owner.doc(room)?.refused == 1)
    }

    @Test func aLateJoinerAsksAndGetsACopy() async throws {
        let owner = SharedDocsModel(rooms: server.device(for: "mckay"))
        let friend = SharedDocsModel(rooms: server.device(for: "jonah"))
        await owner.refresh()
        let room = await owner.share(title: "Plan", text: "One\n\nTwo", with: ["jonah": .editor])!
        // As Matrix may: everything sent before the friend joined is unreadable to them.
        let before = server.rooms[room]!.events.count
        await friend.refresh()
        await friend.accept(friend.invites[0])
        #expect(friend.doc(room)?.isComplete == true)
        server.hidden[room] = (before, "jonah")
        await friend.reload(room)
        #expect(friend.doc(room)?.isComplete == false)
        #expect(friend.doc(room)?.waitingForCopy.contains("jonah") == true)
        // The owner's device answers when it next reads the doc.
        await owner.reload(room)
        await friend.reload(room)
        #expect(friend.doc(room)?.isComplete == true)
        #expect(friend.doc(room)?.text == "One\n\nTwo")
        #expect(friend.doc(room)?.title == "Plan")
    }

    @Test func aSnapshotNeverUndoesANewerEdit() {
        var state = SharedDocState(room: "!r")
        let id = UUID()
        let doc = UUID()
        state.apply(.roles(["a": 100, "b": 50]))
        state.apply(SharedDocPost(kind: .doc, docID: doc, title: "T", titleRev: 1, blocks: [SharedBlock(id: id, order: 1, text: "old")]), sender: "a", date: .now)
        state.apply(SharedDocPost(kind: .blocks, docID: doc, blocks: [SharedBlock(id: id, order: 1, text: "new", rev: 2)]), sender: "b", date: .now)
        state.apply(SharedDocPost(kind: .snapshot, docID: doc, title: "T", titleRev: 1, blocks: [SharedBlock(id: id, order: 1, text: "old")]), sender: "a", date: .now)
        #expect(state.text == "new")
    }

    @Test func removingSomeoneTakesTheDocFromTheirReader() async {
        let (owner, friend, room) = await pair()
        await owner.reload(room)
        await owner.remove("jonah", from: room)
        await friend.refresh()
        #expect(friend.doc(room) == nil)
    }

    @Test func stoppingSharingClosesItForEveryoneAndHandsBackTheText() async {
        let (owner, friend, room) = await pair()
        await owner.reload(room)
        let kept = await owner.stopSharing(room)
        #expect(kept?.text == "Leave Friday.\n\nArches Saturday.")
        #expect(owner.doc(room) == nil)
        await friend.refresh()
        #expect(friend.docs.isEmpty)
    }

    @Test func onlyTheOwnerCanCloseIt() async {
        let (owner, friend, room) = await pair()
        #expect(await friend.stopSharing(room) == nil)
        let forged = try! SharedDocPost(kind: .close).encoded()
        try? await server.device(for: "jonah").post(forged, to: room)
        await owner.reload(room)
        #expect(owner.doc(room)?.isClosed == false)
    }

    @Test func renamesTravel() async {
        let (owner, friend, room) = await pair()
        await friend.rename(room, to: "Moab, March")
        await owner.reload(room)
        #expect(owner.doc(room)?.title == "Moab, March")
    }

    @Test func viewerLinksOnlyKeepWebAddresses() {
        let text = SharedBlockText.attributed("[safe](https://usetotality.com) and [bad](javascript:alert(1))")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://usetotality.com")!])
    }
}
