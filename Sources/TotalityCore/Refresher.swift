import Foundation
import Observation

/// How one step of bringing a module up to date went.
public enum RefreshOutcome: Equatable, Sendable {
    case done
    /// No network. What's on the device still shows.
    case offline
    /// It didn't work, in words to show the person.
    case failed(String)
}

/// Brings a module up to date the same way everywhere (owner, 2026-11-08): what's stored shows first,
/// and the steps run quietly in the background, together, each with a time limit. `AppRefresh` runs it
/// at launch, on coming back, every minute and in Background App Refresh, through the module's
/// `ModuleRefresher` entry, so a module is already fresh when it opens. Nothing says "Updating": a pull shows the system spinner until
/// every step is done, and a problem shows only after a pull or once it has lasted. Asking while it's
/// running waits for that run. A module adds its own steps, and the app adds the one that syncs with the
/// person's other devices, so no module needs to know about another.
@MainActor
@Observable
public final class Refresher {
    public typealias Step = @MainActor @Sendable () async -> RefreshOutcome

    /// Why a run started, which decides what the person hears about it.
    public enum Trigger: Sendable {
        /// Launch, coming back, or the timer. A problem shows once it has happened twice in a row.
        case automatic
        /// The person pulled down, so they hear how it went straight away.
        case pulled
        /// Background App Refresh. The person isn't looking, and a locked phone can't open its keys,
        /// so nothing it finds is shown.
        case background
    }

    public nonisolated static let offlineLine = "You're offline. What's here is from your last update."
    public nonisolated static let syncLine = "Changes from your other devices couldn't be brought in. Pull down to try again."
    public nonisolated static let slowLine = "Updating is taking too long. What's here is from your last update. Pull down to try again."

    /// True while a run is under way.
    public private(set) var isRefreshing = false
    /// A problem worth showing, or nil.
    public private(set) var problem: String?
    public private(set) var lastFinished: Date?

    @ObservationIgnored private var steps: [(name: String, limit: Duration?, onlyWhenPulled: Bool, run: Step)] = []
    @ObservationIgnored private var current: Task<[RefreshOutcome], Never>?
    @ObservationIgnored private var failuresInARow = 0
    @ObservationIgnored private let limit: Duration

    public init(limit: Duration = .seconds(30)) {
        self.limit = limit
    }

    /// Adds a step, or replaces the one with the same name. A step that can rightly take longer, like a
    /// first sync, gets its own limit. One that's too heavy to run every minute, like syncing with the
    /// person's other devices, which the app already does on opening and coming back, runs only on a pull.
    public func add(_ name: String, limit: Duration? = nil, onlyWhenPulled: Bool = false, _ step: @escaping Step) {
        steps.removeAll { $0.name == name }
        steps.append((name, limit, onlyWhenPulled, step))
    }

    public var stepNames: [String] { steps.map(\.name) }

    public func remove(_ name: String) {
        steps.removeAll { $0.name == name }
    }

    public func refresh(_ trigger: Trigger = .automatic) async {
        let outcomes: [RefreshOutcome]
        if let current {
            outcomes = await current.value
        } else {
            let chosen = steps.filter { trigger == .pulled || !$0.onlyWhenPulled }
            guard !chosen.isEmpty else { return }
            isRefreshing = true
            let task = Task { @MainActor [steps = chosen.map { (limit: $0.limit ?? limit, run: $0.run) }] in
                await withTaskGroup(of: RefreshOutcome.self) { group in
                    for step in steps {
                        group.addTask {
                            do {
                                return try await Deadline.run(step.limit) { await step.run() }
                            } catch {
                                return .failed(Refresher.slowLine)
                            }
                        }
                    }
                    var outcomes: [RefreshOutcome] = []
                    for await outcome in group { outcomes.append(outcome) }
                    return outcomes
                }
            }
            current = task
            outcomes = await task.value
            current = nil
            isRefreshing = false
            lastFinished = Date()
            note(outcomes, from: trigger)
            return
        }
        // Joined someone else's run: a pull still hears how it went.
        if trigger == .pulled { note(outcomes, from: trigger) }
    }

    private func note(_ outcomes: [RefreshOutcome], from trigger: Trigger) {
        guard trigger != .background else { return }
        guard let found = Self.problem(in: outcomes) else {
            failuresInARow = 0
            problem = nil
            return
        }
        failuresInARow += 1
        if trigger == .pulled || failuresInARow >= 2 { problem = found }
    }

    /// Being offline says so plainly. Otherwise the first failure is shown.
    static func problem(in outcomes: [RefreshOutcome]) -> String? {
        if outcomes.contains(.offline) { return offlineLine }
        for case .failed(let message) in outcomes { return message }
        return nil
    }
}
