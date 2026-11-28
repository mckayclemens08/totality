import Foundation
import Testing
import TotalityCore
@testable import TotalityAI

private final class AIMemoryStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    func exists(_ name: String) throws -> Bool { lock.withLock { blobs[name] != nil } }
}

@MainActor
private final class FakeAIBridge: AISourceBridge {
    var itemsByModule: [ModuleID: [AIContextItem]] = [:]
    private(set) var fetchedModules: [ModuleID] = []
    private(set) var executedActions: [(AIProposedAction, String?)] = []

    func fetchItems(for module: ModuleID, limit: Int) async throws -> [AIContextItem] {
        fetchedModules.append(module)
        return Array((itemsByModule[module] ?? []).prefix(limit))
    }

    func execute(_ action: AIProposedAction, editedBody: String?) async throws -> String {
        executedActions.append((action, editedBody))
        return action.kind == .replyEmail ? "Approved · sent" : "Approved · done"
    }
}

@MainActor
@Suite("Ask Totality AI")
struct AITests {
    private func makeModel(
        store: AIMemoryStore = AIMemoryStore(),
        key: ContentRootKey? = nil,
        bridge: FakeAIBridge = FakeAIBridge(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_795_000_000) }
    ) throws -> (AIModel, AIMemoryStore, ContentRootKey, FakeAIBridge) {
        let rootKey = try key ?? ContentRootKey.generate()
        let vault = AIVault(store: store, rootKey: rootKey)
        let model = AIModel(vault: vault, modelStore: LocalOpenModelStore(directory: nil), bridge: bridge, clock: clock)
        return (model, store, rootKey, bridge)
    }

    @Test func startsWithAccessToNothingAndNeverReadsUngrantedModules() async throws {
        let bridge = FakeAIBridge()
        bridge.itemsByModule[.calendar] = [
            AIContextItem(id: "e1", module: .calendar, title: "Dinner with Sam", detail: "6:30 PM"),
        ]
        let (model, _, _, _) = try makeModel(bridge: bridge)
        await model.load()

        #expect(!model.hasAnyGrant)
        #expect(model.orderedGrants.allSatisfy { !$0.read && !$0.propose })

        await model.ask("What's on my calendar Saturday?")
        #expect(bridge.fetchedModules.isEmpty)
        #expect(model.missingGrant == .calendar)
        let reply = try #require(model.messages.last)
        #expect(reply.role == .assistant)
        #expect(reply.text.contains("calendar"))
    }

    @Test func enablingReadReadsOnlyGrantedModulesAndLogsActivity() async throws {
        let bridge = FakeAIBridge()
        bridge.itemsByModule[.calendar] = [
            AIContextItem(id: "e1", module: .calendar, title: "Dinner with Sam", detail: "Sat 6:30 PM"),
        ]
        bridge.itemsByModule[.mail] = [
            AIContextItem(id: "m1", module: .mail, title: "Re: Saturday plans", detail: "Marco Ruiz", metadata: ["sender": "Marco Ruiz", "email": "marco@usetotality.com"]),
        ]
        let (model, _, _, _) = try makeModel(bridge: bridge)
        await model.load()

        await model.setGrant(.calendar, scope: .read, to: true)
        await model.ask("What is on my calendar?")

        #expect(bridge.fetchedModules == [.calendar])
        #expect(!bridge.fetchedModules.contains(.mail))
        let last = try #require(model.messages.last)
        #expect(last.text.contains("Dinner with Sam"))
        #expect(last.sourcesRead.map(\.module) == [.calendar])
        #expect(model.activity.contains { $0.kind == .read && $0.module == .calendar })
    }

    @Test func proposeScopeRulesAndWeatherHasNoPropose() async throws {
        let (model, _, _, _) = try makeModel()
        await model.load()

        // Propose automatically turns on Read.
        await model.setGrant(.mail, scope: .propose, to: true)
        #expect(model.grants[.mail]?.read == true)
        #expect(model.grants[.mail]?.propose == true)

        // Turning Read off revokes Propose as well.
        await model.setGrant(.mail, scope: .read, to: false)
        #expect(model.grants[.mail]?.read == false)
        #expect(model.grants[.mail]?.propose == false)

        // Weather is read-only (no Propose switch).
        await model.setGrant(.weather, scope: .propose, to: true)
        #expect(model.grants[.weather]?.propose == false)
        #expect(model.grants[.weather]?.read == false)
    }

    @Test func outboundEmailReplyRequiresExplicitApprovalAndSupportsEditingAndDeclining() async throws {
        let bridge = FakeAIBridge()
        bridge.itemsByModule[.mail] = [
            AIContextItem(
                id: "m1",
                module: .mail,
                title: "Saturday plans",
                detail: "Marco Ruiz",
                body: "Does Saturday work?",
                metadata: ["sender": "Marco Ruiz", "email": "marco@usetotality.com"]
            ),
        ]
        let (model, _, _, _) = try makeModel(bridge: bridge)
        await model.load()
        await model.setGrant(.mail, scope: .propose, to: true)

        await model.ask("Draft a reply to Marco's email")
        let replyMessage = try #require(model.messages.last)
        let proposal = try #require(replyMessage.proposal)
        #expect(proposal.kind == .replyEmail)
        #expect(proposal.status == .pending)
        // Nothing executed automatically before explicit approval.
        #expect(bridge.executedActions.isEmpty)

        await model.approve(messageID: replyMessage.id, editedBody: "Saturday morning works at 8!")
        #expect(bridge.executedActions.count == 1)
        #expect(bridge.executedActions[0].1 == "Saturday morning works at 8!")
        #expect(model.messages.last?.proposal?.status == .approved)
        #expect(model.activity.contains { $0.id == proposal.id && $0.outcome == .ok })

        // Declining a second proposal never executes it.
        await model.ask("Draft another reply to Marco")
        let second = try #require(model.messages.last)
        let secondProp = try #require(second.proposal)
        await model.decline(messageID: second.id)
        #expect(bridge.executedActions.count == 1)
        #expect(model.messages.last?.proposal?.status == .declined)
        #expect(model.activity.contains { $0.id == secondProp.id && $0.outcome == .declined })
    }

    @Test func sealedVaultPersistsGrantsActivityAndTurnEverythingOffAcrossReload() async throws {
        let store = AIMemoryStore()
        let key = try ContentRootKey.generate()
        let (first, _, _, _) = try makeModel(store: store, key: key)
        await first.load()
        await first.setGrant(.tasks, scope: .propose, to: true)
        await first.setGrant(.calendar, scope: .read, to: true)

        let (second, _, _, _) = try makeModel(store: store, key: key)
        await second.load()
        #expect(second.grants[.tasks]?.propose == true)
        #expect(second.grants[.calendar]?.read == true)
        #expect(!second.activity.isEmpty)

        await second.turnEverythingOff()
        let (third, _, _, _) = try makeModel(store: store, key: key)
        await third.load()
        #expect(!third.hasAnyGrant)
    }

    @Test func clearsActivityOlderThan30DaysAndPreparesLocalOpenModel() async throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        final class Clock: @unchecked Sendable {
            var now: Date
            init(_ now: Date) { self.now = now }
        }
        let clock = Clock(now.addingTimeInterval(-35 * 86_400))
        let (model, _, _, _) = try makeModel(clock: { clock.now })
        await model.load()
        await model.setGrant(.calendar, scope: .read, to: true)
        clock.now = now
        await model.setGrant(.reader, scope: .read, to: true)

        #expect(model.activity.count == 2)
        await model.clearActivityOlderThan30Days()
        #expect(model.activity.count == 1)
        #expect(model.activity.first?.module == .reader)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let localStore = LocalOpenModelStore(directory: tempDir, minimumValidBytes: 4)
        let localModel = AIModel(vault: AIVault(store: AIMemoryStore(), rootKey: try ContentRootKey.generate()), modelStore: localStore)
        await localModel.load()
        #expect(!localModel.localModelStatus.isReady)
        await localModel.downloadLocalModel()
        #expect(localModel.localModelStatus.isReady)
        #expect(localStore.readyModelURL != nil)
        await localModel.removeLocalModel()
        #expect(!localModel.localModelStatus.isReady)
    }

    @Test func askAboutItemContextFocusesTurnWithoutOpeningUngrantedModules() async throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let bridge = FakeAIBridge()
        bridge.itemsByModule[.tasks] = [
            AIContextItem(id: "t1", module: .tasks, title: "Unrelated task", detail: "Tomorrow"),
        ]
        let askContext = AIAskContext(
            id: "mail-42",
            module: .mail,
            title: "Project Launch Checklist",
            detail: "Elena Vance",
            body: "Please confirm the rollout window and sign off on release notes.",
            date: now,
            metadata: ["sender": "elena@usetotality.com"]
        )
        let aboutItem = AIContextItem(askContext)
        #expect(aboutItem.id == "mail-42")
        #expect(aboutItem.module == .mail)
        #expect(aboutItem.title == "Project Launch Checklist")
        #expect(aboutItem.detail == "Elena Vance")
        #expect(aboutItem.metadata["sender"] == "elena@usetotality.com")

        let (model, _, _, _) = try makeModel(bridge: bridge, clock: { now })
        await model.load()
        await model.ask("Summarize what she needs", about: aboutItem)

        #expect(bridge.fetchedModules.isEmpty)
        #expect(model.messages.count == 2)
        #expect(model.messages[0].role == .user)
        #expect(model.messages[0].aboutLabel == "Project Launch Checklist · Elena Vance")
        let reply = try #require(model.messages.last)
        #expect(reply.role == .assistant)
        #expect(reply.text.contains("Project Launch Checklist"))
        #expect(reply.text.contains("rollout window"))

        // Questions reaching into another ungranted module still ask for that module's Read permission.
        await model.ask("Am I free on my calendar?", about: aboutItem)
        #expect(model.missingGrant == .calendar)
        #expect(bridge.fetchedModules.isEmpty)

        // Opening Ask Totality from a module's header button ("mail.home") still requires Inbox Read access.
        let homeItem = AIContextItem(AIAskContext(id: "mail.home", module: .mail, title: "Inbox"))
        await model.ask("Summarize what's in there", about: homeItem)
        #expect(model.missingGrant == .mail)
        #expect(bridge.fetchedModules.isEmpty)
    }
}
