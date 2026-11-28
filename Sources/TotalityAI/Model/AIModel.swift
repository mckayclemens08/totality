import Foundation
import Observation
import TotalityCore

/// Ask Totality state (issue 252). Runs completely on the iPhone, starts with access to nothing,
/// seals all grants and activity on device, and always asks before executing outward or proposed changes.
@MainActor
@Observable
public final class AIModel {
    public enum Phase: Equatable {
        case idle, loading, ready, thinking
    }

    public private(set) var phase = Phase.idle
    public private(set) var grants: [ModuleID: AIAccessGrant] = AIAccessGrant.emptyGrants
    public private(set) var activity: [AIActivityEntry] = []
    public private(set) var messages: [AIMessage] = []
    public private(set) var localModelStatus: LocalModelStatus
    public private(set) var missingGrant: ModuleID?
    public var notice: String?

    @ObservationIgnored public var bridge: (any AISourceBridge)?
    @ObservationIgnored private let vault: AIVault
    @ObservationIgnored private let engine: any AIInferenceEngine
    @ObservationIgnored private let modelStore: LocalOpenModelStore
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    public init(
        vault: AIVault,
        engine: (any AIInferenceEngine)? = nil,
        modelStore: LocalOpenModelStore = LocalOpenModelStore(),
        bridge: (any AISourceBridge)? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.vault = vault
        self.modelStore = modelStore
        self.engine = engine ?? LocalOpenModelEngine(modelStore: modelStore)
        self.bridge = bridge
        self.clock = clock
        self.localModelStatus = modelStore.status()
    }

    /// Ordered grant rows for the Access screen, matching the design artboard.
    public var orderedGrants: [AIAccessGrant] {
        AIAccessGrant.defaultOrder.compactMap { grants[$0.module] }
    }

    public var hasAnyGrant: Bool {
        grants.values.contains { $0.isAnyGranted }
    }

    public var grantedReadModules: Set<ModuleID> {
        Set(grants.values.filter(\.read).map(\.module))
    }

    public var grantedProposeModules: Set<ModuleID> {
        Set(grants.values.filter(\.propose).map(\.module))
    }

    public var glance: ModuleGlance? {
        guard phase == .ready || phase == .thinking else { return nil }
        if !hasAnyGrant {
            return ModuleGlance(lines: ["Choose what it can see"], isQuiet: true)
        }
        let grantedCount = grantedReadModules.count
        if let last = messages.last(where: { $0.role == .assistant }) {
            let line = last.text.split(separator: "\n").first.map(String.init) ?? "Ready on this iPhone"
            return ModuleGlance(lines: [line])
        }
        let label = grantedCount == 1 ? "1 module granted · On this iPhone" : "\(grantedCount) modules granted · On this iPhone"
        return ModuleGlance(lines: [label])
    }

    // MARK: Lifecycle

    public func load() async {
        guard phase == .idle || phase == .loading else { return }
        phase = .loading
        if let savedGrants = await vault.grants() {
            var merged = AIAccessGrant.emptyGrants
            for item in savedGrants {
                merged[item.module] = AIAccessGrant(
                    module: item.module,
                    name: merged[item.module]?.name ?? item.name,
                    supportsPropose: merged[item.module]?.supportsPropose ?? item.supportsPropose,
                    read: item.read,
                    propose: item.propose,
                    lastUsed: item.lastUsed
                )
            }
            grants = merged
        } else {
            grants = AIAccessGrant.emptyGrants
        }
        activity = (await vault.activity() ?? []).sorted { $0.date > $1.date }
        messages = await vault.messages() ?? []
        localModelStatus = modelStore.status()
        phase = .ready
    }

    public func close() async {
        stopThinking()
        cancelModelDownload()
        if let localEngine = engine as? LocalOpenModelEngine {
            await localEngine.unload()
        }
        await vault.close()
    }

    // MARK: Grants

    public func setGrant(_ module: ModuleID, scope: AIScope, to enabled: Bool) async {
        guard var current = grants[module] else { return }
        let now = clock()
        switch scope {
        case .read:
            current.read = enabled
            if !enabled { current.propose = false }
        case .propose:
            guard current.supportsPropose else { return }
            current.propose = enabled
            if enabled { current.read = true }
        }
        grants[module] = current
        if scope == .read, enabled, missingGrant == module { missingGrant = nil }
        let scopeName = scope == .read ? "Read" : "Propose"
        let actionWord = enabled ? "turned on" : "turned off"
        await appendActivity(AIActivityEntry(
            date: now,
            moduleName: "Settings",
            module: module,
            kind: .grant,
            what: "\(scopeName) \(actionWord) for \(current.name)",
            result: "By you",
            outcome: .info
        ))
        try? await vault.saveGrants(orderedGrants)
    }

    public func turnEverythingOff() async {
        let now = clock()
        for key in grants.keys {
            grants[key]?.read = false
            grants[key]?.propose = false
        }
        await appendActivity(AIActivityEntry(
            date: now,
            moduleName: "Settings",
            kind: .grant,
            what: "Turned everything off",
            result: "By you",
            outcome: .info
        ))
        try? await vault.saveGrants(orderedGrants)
    }

    // MARK: Local model setup

    public func downloadLocalModel() async {
        guard downloadTask == nil else { return }
        localModelStatus = .downloading(progress: 0.01)
        let store = modelStore
        let task = Task { @MainActor [weak self] in
            do {
                let status = try await store.prepareLocalEngine { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadTask != nil else { return }
                        self.localModelStatus = .downloading(progress: progress)
                    }
                }
                guard let self else { return }
                self.localModelStatus = status
            } catch is CancellationError {
                guard let self else { return }
                self.localModelStatus = store.status()
            } catch {
                guard let self else { return }
                self.localModelStatus = .failed(error.localizedDescription)
            }
            self?.downloadTask = nil
        }
        downloadTask = task
        await task.value
    }

    public func cancelModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        localModelStatus = modelStore.status()
    }

    public func removeLocalModel() async {
        cancelModelDownload()
        if let localEngine = engine as? LocalOpenModelEngine {
            await localEngine.unload()
        }
        if let updated = try? modelStore.removeDownloadedModel() {
            localModelStatus = updated
        }
    }

    // MARK: Asking and approving

    public func ask(_ rawQuestion: String, about: AIContextItem? = nil) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if phase == .idle { await load() }
        stopThinking()
        missingGrant = nil
        let now = clock()
        let aboutLabel = about.map { "\($0.title)\($0.detail.isEmpty ? "" : " · \($0.detail)")" }
        messages.append(AIMessage(role: .user, text: question, date: now, aboutLabel: aboutLabel))
        try? await vault.saveMessages(messages)
        phase = .thinking

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runTurn(question: question, about: about)
        }
        currentTask = task
        await task.value
    }

    public func stopThinking() {
        currentTask?.cancel()
        currentTask = nil
        if phase == .thinking { phase = .ready }
    }

    private func runTurn(question: String, about: AIContextItem?) async {
        defer {
            currentTask = nil
            if phase == .thinking { phase = .ready }
        }
        let now = clock()
        let readSet = grantedReadModules
        let proposeSet = grantedProposeModules
        var context: [ModuleID: [AIContextItem]] = [:]

        if let bridge {
            for module in AIAccessGrant.defaultOrder.map(\.module) where readSet.contains(module) {
                guard !Task.isCancelled else { return }
                if let items = try? await bridge.fetchItems(for: module, limit: 25), !items.isEmpty {
                    context[module] = items
                    grants[module]?.lastUsed = now
                    let name = grants[module]?.name ?? module.rawValue.capitalized
                    let previewTitles = items.prefix(2).map(\.title).joined(separator: ", ")
                    await appendActivity(AIActivityEntry(
                        date: now,
                        moduleName: name,
                        module: module,
                        kind: .read,
                        what: items.count == 1 ? previewTitles : "\(items.count) items (\(previewTitles))",
                        outcome: .info
                    ))
                }
            }
        }
        try? await vault.saveGrants(orderedGrants)
        guard !Task.isCancelled else { return }

        do {
            let reply = try await engine.answer(
                question: question,
                about: about,
                grantedRead: readSet,
                grantedPropose: proposeSet,
                context: context,
                now: now
            )
            guard !Task.isCancelled else { return }
            missingGrant = reply.missingPermission
            if let proposal = reply.proposal {
                let moduleName = grants[proposal.module]?.name ?? proposal.module.rawValue.capitalized
                await appendActivity(AIActivityEntry(
                    id: proposal.id,
                    date: now,
                    moduleName: moduleName,
                    module: proposal.module,
                    kind: .proposed,
                    what: "\(proposal.title) \(proposal.body.prefix(80))",
                    result: "Waiting for you",
                    outcome: .info
                ))
            }
            messages.append(AIMessage(
                role: .assistant,
                text: reply.answer,
                date: now,
                sourcesRead: reply.readSummary,
                proposal: reply.proposal
            ))
            try? await vault.saveMessages(messages)
        } catch {
            guard !Task.isCancelled else { return }
            notice = "Ask Totality couldn't finish answering on this iPhone. Nothing was sent or changed."
        }
    }

    public func approve(messageID: UUID, editedBody: String? = nil) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              var proposal = messages[index].proposal,
              proposal.status == .pending else { return }
        guard let bridge else {
            notice = "That module isn't ready right now."
            return
        }
        let body = (editedBody ?? proposal.body).trimmingCharacters(in: .whitespacesAndNewlines)
        proposal.body = body
        do {
            let resultText = try await bridge.execute(proposal, editedBody: body)
            proposal.status = .approved
            messages[index].proposal = proposal
            try? await vault.saveMessages(messages)
            updateActivity(id: proposal.id, result: resultText, outcome: .ok)
            try? await vault.saveActivity(activity)
        } catch {
            notice = error.localizedDescription
        }
    }

    public func decline(messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              var proposal = messages[index].proposal,
              proposal.status == .pending else { return }
        proposal.status = .declined
        messages[index].proposal = proposal
        try? await vault.saveMessages(messages)
        updateActivity(id: proposal.id, result: "Declined", outcome: .declined)
        try? await vault.saveActivity(activity)
    }

    public func clearActivityOlderThan30Days() async {
        let cutoff = clock().addingTimeInterval(-30 * 86_400)
        activity.removeAll { $0.date < cutoff }
        try? await vault.saveActivity(activity)
    }

    public func clearConversation() async {
        messages = []
        missingGrant = nil
        try? await vault.saveMessages(messages)
    }

    private func appendActivity(_ entry: AIActivityEntry) async {
        activity.insert(entry, at: 0)
        if activity.count > 500 { activity = Array(activity.prefix(500)) }
        try? await vault.saveActivity(activity)
    }

    private func updateActivity(id: UUID, result: String, outcome: AIActivityEntry.Outcome) {
        if let idx = activity.firstIndex(where: { $0.id == id }) {
            activity[idx].result = result
            activity[idx].outcome = outcome
        }
    }
}
