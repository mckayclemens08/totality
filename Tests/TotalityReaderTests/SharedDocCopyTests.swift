import Foundation
import Testing
import TotalityCore
@testable import TotalityReader

/// A history replayed the way the app reads a Matrix room: the creator's level comes from the room, not
/// from its power levels, as in room version 12.
@Suite("Shared docs: reading a room's history")
struct SharedHistoryReadingTests {
    private let date = Date(timeIntervalSince1970: 1_795_000_000)

    private func docPost() throws -> String {
        try SharedDocPost(kind: .doc, docID: UUID(), title: "Moab trip plan", titleRev: 1, blocks: [SharedBlock(order: 1, text: "Leave Friday.")]).encoded()
    }

    @Test func theCreatorsFirstPostCountsWhenThePowerLevelsDontNameThem() throws {
        // Room version 12: the room's first power levels list nobody, and Carter's invite lists only him.
        let timeline: [SharedRoomEvent] = [
            .roles([:]),
            .post(id: "$1", sender: "mckay", date: date, body: try docPost()),
            .roles(["carter": 50]),
        ]
        let members = [SharedRoomMember(username: "mckay", role: .owner), SharedRoomMember(username: "carter", role: .editor, isInvited: true)]
        let history = SharedRoomHistory.reading(timeline: timeline, creators: ["mckay"], members: members, reachedStart: true)
        let state = SharedDocState.build(room: "!r", history: history)
        #expect(state.isComplete)
        #expect(state.refused == 0)
        #expect(state.text == "Leave Friday.")
        // Before, with only the timeline's roles, the owner had none and the doc was refused.
        let old = SharedDocState.build(room: "!r", history: SharedRoomHistory(events: timeline, members: members, isEncrypted: true))
        #expect(!old.isComplete)
        #expect(old.refused == 1)
    }

    @Test func theCreatorsFirstPostCountsWhenNoPowerLevelsReachTheTimeline() throws {
        let timeline: [SharedRoomEvent] = [.post(id: "$1", sender: "mckay", date: date, body: try docPost())]
        let members = [SharedRoomMember(username: "mckay", role: .owner)]
        let history = SharedRoomHistory.reading(timeline: timeline, creators: [], members: members, reachedStart: true)
        #expect(SharedDocState.build(room: "!r", history: history).isComplete)
    }

    @Test func aPostBeforeTheFirstPowerLevelsFromSomeoneElseStillDoesntCount() throws {
        let forged = try SharedDocPost(kind: .doc, docID: UUID(), title: "Not theirs", titleRev: 1).encoded()
        let timeline: [SharedRoomEvent] = [.post(id: "$1", sender: "carter", date: date, body: forged), .roles(["carter": 50])]
        let history = SharedRoomHistory.reading(
            timeline: timeline, creators: ["mckay"], members: [SharedRoomMember(username: "carter", role: .editor)], reachedStart: true
        )
        let state = SharedDocState.build(room: "!r", history: history)
        #expect(!state.isComplete)
        #expect(state.refused == 1)
    }

    @Test func aListedLevelForTheCreatorIsKept() {
        // Older room versions list the creator, and a handed-over doc may list them lower.
        let history = SharedRoomHistory.reading(timeline: [.roles(["mckay": 50, "carter": 100])], creators: ["mckay"], members: [], reachedStart: true)
        #expect(history.events.last == .roles(["mckay": 50, "carter": 100]))
    }
}

@MainActor
@Suite("Shared docs: two users, keys and the private copy")
struct SharedDocCopyTwoUserTests {
    let server = FakeServer()

    init() {
        // As Totality's Matrix server and the SDK behave.
        server.roomVersion12 = true
        server.keysFromInvite = true
        server.ownPostLag = 2
    }

    private func model(_ username: String) -> SharedDocsModel {
        let model = SharedDocsModel(rooms: server.device(for: username))
        model.confirmPause = .zero
        return model
    }

    @Test func theSharerReadsTheirOwnDocInARoomVersion12Room() async throws {
        let owner = model("mckay")
        _ = server.device(for: "carter")
        await owner.refresh()
        let room = try #require(await owner.share(title: "Moab trip plan", text: "Leave Friday.\n\nArches Saturday.", with: ["carter": .editor]))
        // Its own posts came back a couple of reads late, and it waited for them without asking for a copy.
        let doc = try #require(owner.doc(room))
        #expect(doc.isComplete)
        #expect(doc.text == "Leave Friday.\n\nArches Saturday.")
        #expect(doc.waitingForCopy.isEmpty)
        #expect(owner.isOwner(room))
    }

    @Test func anInviteeOpensTheDocWithoutTheOwnerAnswering() async throws {
        let owner = model("mckay")
        let friend = model("carter")
        await owner.refresh()
        let room = try #require(await owner.share(title: "Moab trip plan", text: "Leave Friday.", with: ["carter": .editor]))
        await friend.refresh()
        await friend.accept(friend.invites[0])
        // The first posts went before Carter was invited, so he can't open them, but the copy sent after
        // the invite he can. The owner's device does nothing more.
        let doc = try #require(friend.doc(room))
        #expect(doc.unreadable > 0)
        #expect(doc.isComplete)
        #expect(doc.text == "Leave Friday.")
        #expect(doc.waitingForCopy.isEmpty)
    }

    @Test func someoneInvitedLaterOpensItToo() async throws {
        let owner = model("mckay")
        let friend = model("carter")
        let other = model("eli")
        await owner.refresh()
        let room = try #require(await owner.share(title: "Plan", text: "One\n\nTwo", with: ["carter": .editor]))
        #expect(await owner.invite("eli", as: .viewer, to: room))
        await other.refresh()
        await other.accept(other.invites[0])
        #expect(other.doc(room)?.isComplete == true)
        #expect(other.doc(room)?.text == "One\n\nTwo")
        _ = friend
    }

    @Test func thePrivateCopyStaysWhenThisDeviceCantOpenTheSharedOne() async throws {
        let rooms = server.device(for: "mckay")
        _ = server.device(for: "carter")
        let shared = SharedDocsModel(rooms: rooms)
        shared.confirmPause = .zero
        shared.confirmAttempts = 3
        // Its own posts never come back to this device.
        server.ownPostLag = 100
        let reader = ReaderModel(vault: try newVault(), listen: ListenController(engine: FakeSpeechEngine()))
        reader.sharedFrom = try #require(UserDefaults(suiteName: "SharedDocCopy-\(UUID())"))
        reader.shared = shared
        await reader.load()
        let item = try #require(await reader.newNote())
        #expect(await reader.saveNote(item.id, title: "Moab trip plan", body: "Leave Friday."))
        await shared.refresh()
        let room = try #require(await reader.share(item, with: ["carter": .editor]))
        #expect(shared.doc(room)?.isComplete == false)
        #expect(reader.library.items.contains { $0.id == item.id })
        #expect(reader.trash.isEmpty)
        #expect(shared.notice?.contains("private copy stays") == true)
    }

    @Test func aReadableShareMovesThePrivateCopyAndCanFindItAgain() async throws {
        _ = server.device(for: "carter")
        let shared = model("mckay")
        let reader = ReaderModel(vault: try newVault(), listen: ListenController(engine: FakeSpeechEngine()))
        reader.sharedFrom = try #require(UserDefaults(suiteName: "SharedDocCopy-\(UUID())"))
        reader.shared = shared
        await reader.load()
        let item = try #require(await reader.newNote())
        #expect(await reader.saveNote(item.id, title: "Moab trip plan", body: "Leave Friday."))
        await shared.refresh()
        let room = try #require(await reader.share(item, with: ["carter": .editor]))
        #expect(shared.doc(room)?.isComplete == true)
        #expect(reader.trash.map(\.item.id) == [item.id])
        // Found again by what this device noted, so the waiting screen can offer it back.
        #expect(reader.privateCopy(of: try #require(shared.doc(room)))?.item.id == item.id)
    }

    @Test func aCopySharedBeforeTheFixIsFoundByWhenItWasShared() async throws {
        let reader = ReaderModel(vault: try newVault(), listen: ListenController(engine: FakeSpeechEngine()))
        reader.sharedFrom = try #require(UserDefaults(suiteName: "SharedDocCopy-\(UUID())"))
        await reader.load()
        let item = try #require(await reader.newNote())
        #expect(await reader.saveNote(item.id, title: "Moab trip plan", body: "Leave Friday."))
        await reader.delete(item)
        let deleted = try #require(reader.trash.first?.deletedAt)
        // A room whose posts this device can't open, sent just before the copy moved.
        let history = SharedRoomHistory(
            events: [.unreadable(id: "$1", sender: "mckay", date: deleted.addingTimeInterval(-2))], members: [], isEncrypted: true
        )
        let doc = SharedDocState.build(room: "!old", history: history)
        #expect(reader.privateCopy(of: doc)?.item.id == item.id)
        let unrelated = SharedDocState.build(room: "!other", history: SharedRoomHistory(
            events: [.unreadable(id: "$1", sender: "mckay", date: deleted.addingTimeInterval(-3600))], members: [], isEncrypted: true
        ))
        #expect(reader.privateCopy(of: unrelated) == nil)
    }

    @Test func theListSaysWhoOwnsIt() async throws {
        let owner = model("mckay")
        let friend = model("carter")
        await owner.refresh()
        let room = try #require(await owner.share(title: "Plan", text: "One", with: ["carter": .editor]))
        await friend.refresh()
        await friend.accept(friend.invites[0])
        await owner.reload(room)
        #expect(owner.detail(of: try #require(owner.doc(room))) == "With @carter · You're the owner")
        #expect(friend.detail(of: try #require(friend.doc(room))) == "With @mckay · Owner: @mckay · You can edit")
    }
}
