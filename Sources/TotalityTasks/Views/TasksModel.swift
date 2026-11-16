import Foundation
import Observation
import TotalityCore

/// Everything Tasks' screens and home tile show, and every change made on them. Tasks are opened here
/// from the sealed vault and stay in memory on this device.
@MainActor
@Observable
public final class TasksModel {
    public enum Phase: Equatable {
        case loading, ready, failed
    }

    /// The last task completed, so it can be undone for a few seconds.
    public struct Completion: Equatable {
        public let id: UUID
        public let title: String
    }

    /// How long Undo stays after completing a task.
    public static let undoTime = Duration.seconds(5)
    /// How long a completed task stays ticked in its list before it slides away to the Logbook.
    public static let lingerTime = Duration.milliseconds(700)

    public private(set) var phase = Phase.loading
    public private(set) var tasks: [TaskItem] = []
    public private(set) var lists: [TaskList] = []
    /// Tasks that wouldn't open on this device.
    public private(set) var unreadable = 0
    /// Upcoming's events, from the calendar, held in memory only.
    public private(set) var events: [AgendaItem] = []
    /// The moment the screens count days from. Moves forward with each refresh.
    public private(set) var now: Date
    public private(set) var lastCompleted: Completion?
    /// Completed a moment ago: still ticked in its list until it slides away.
    public private(set) var lingering: Set<UUID> = []
    /// Bumps on each completion, for the haptic.
    public private(set) var completions = 0
    /// A problem to tell the person about, in their words.
    public var notice: String?
    /// A task to open, asked for by home search.
    public var requestedTask: UUID?
    /// Quick add, asked for by the home tile's +.
    public var requestedQuickAdd = false
    public let calendar: Calendar
    public let refresher = Refresher()

    /// Everything on the calendar between two moments, through the registry. Nil leaves Upcoming without events.
    @ObservationIgnored public var agenda: (@Sendable (Date, Date) async -> [AgendaItem])?
    @ObservationIgnored private let vault: TaskVault?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var undoTimer: Task<Void, Never>?

    public init(vault: TaskVault?, calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() }) {
        self.vault = vault
        self.calendar = calendar
        clock = now
        self.now = now()
        refresher.add("tasks") { [weak self] in
            guard let self else { return .done }
            await self.load()
            return self.phase == .failed ? .failed("Your tasks couldn't be read on this device.") : .done
        }
    }

    public var today: TaskDay { TaskDay(now, in: calendar) }

    /// Refuses further changes, so nothing is saved under the old key during a key move.
    public func stopForKeyChange() async {
        await vault?.close()
    }

    public func load() async {
        now = clock()
        guard let vault else {
            phase = .failed
            return
        }
        do {
            let listing = try await vault.everything()
            tasks = listing.tasks
            lists = listing.lists
            unreadable = listing.unreadable
            phase = .ready
        } catch {
            phase = .failed
        }
        await loadEvents()
    }

    private func loadEvents() async {
        guard let agenda else { return }
        let from = today.adding(days: 1, in: calendar).start(in: calendar)
        let to = today.adding(days: TaskRules.upcomingDays + 1, in: calendar).start(in: calendar)
        events = await agenda(from, to)
    }

    // MARK: - What the screens show

    /// The list's tasks, with any completed a moment ago still in place.
    public func tasks(in bucket: TaskBucket) -> [TaskItem] {
        TaskRules.tasks(in: bucket, from: shown(for: bucket), today: today)
    }

    public func count(_ bucket: TaskBucket) -> Int {
        TaskRules.tasks(in: bucket, from: tasks, today: today).count
    }

    public func isDone(_ id: UUID) -> Bool {
        tasks.first { $0.id == id }?.isCompleted ?? false
    }

    public var upcoming: [UpcomingDay] {
        TaskRules.upcoming(from: shown(for: .upcoming), events: events, today: today, in: calendar)
    }

    public var later: [TaskItem] {
        TaskRules.later(from: shown(for: .upcoming), today: today, in: calendar)
    }

    public func logbook(matching query: String = "") -> [LogbookDay] {
        let terms = SearchText.terms(in: query)
        let found = terms.isEmpty ? tasks : tasks.filter { task in
            terms.allSatisfy { term in
                ([task.title, task.notes] + task.checklist.map(\.title) + task.tags).contains { SearchText.find(term, in: $0) != nil }
            }
        }
        return TaskRules.logbook(from: found, in: calendar)
    }

    /// Today's tasks done against planned, split by the list each comes from.
    public var progress: TodayProgress {
        TaskRules.todayProgress(from: tasks, lists: lists, today: today, in: calendar)
    }

    public var overdue: Int {
        tasks.filter { TaskRules.isOverdue($0, today: today) }.count
    }

    /// The soonest deadline that hasn't passed.
    public var nextDeadline: TaskItem? {
        tasks.filter { !$0.isCompleted && ($0.deadline.map { $0 >= today } ?? false) }
            .min { ($0.deadline!, $0.order) < ($1.deadline!, $1.order) }
    }

    public func quietLine(for task: TaskItem, in bucket: TaskBucket) -> String? {
        TaskText.quietLine(for: task, in: bucket, today: today, calendar: calendar)
    }

    private func shown(for bucket: TaskBucket) -> [TaskItem] {
        guard bucket != .logbook, !lingering.isEmpty else { return tasks }
        return tasks.map { task in
            guard lingering.contains(task.id) else { return task }
            var still = task
            still.completedAt = nil
            return still
        }
    }

    /// What the home tile and the flower show: today's tasks first, then what's overdue and due next.
    public var glance: ModuleGlance? {
        guard phase == .ready else { return nil }
        let todays = tasks(in: .today)
        var lines = todays.prefix(4).map(\.displayTitle)
        if overdue > 0 { lines.append(overdue == 1 ? "1 overdue" : "\(overdue) overdue") }
        if let next = nextDeadline, let deadline = next.deadline {
            lines.append("\(next.displayTitle) · \(TaskText.deadlinePhrase(deadline, today: today, in: calendar))")
        }
        guard !lines.isEmpty else { return ModuleGlance(lines: ["Nothing planned today"], isQuiet: true) }
        if todays.isEmpty { lines.insert("Nothing planned today", at: 0) }
        return ModuleGlance(lines: lines, isQuiet: false)
    }

    // MARK: - Changes

    /// Adds one task per line typed, each read for dates, tags and priority. Returns what was added.
    @discardableResult
    public func add(_ text: String, in bucket: TaskBucket) async -> [TaskItem] {
        now = clock()
        let parsed = QuickAddParser.parseLines(text, now: now, calendar: calendar)
        var order = (tasks.map(\.order).max() ?? 0) + 1
        var added: [TaskItem] = []
        for item in parsed {
            let task = item.task(
                defaultPlace: Self.place(for: bucket), defaultWhen: bucket == .today ? today : nil, order: order, now: now
            )
            order += 1
            guard await save(task, over: nil) else { break }
            added.append(task)
        }
        return added
    }

    private static func place(for bucket: TaskBucket) -> TaskItem.Place {
        switch bucket {
        case .anytime, .today, .upcoming: .anytime
        case .someday: .someday
        default: .inbox
        }
    }

    /// Completes a task, or brings a completed one back.
    public func toggle(_ id: UUID) async {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if task.isCompleted {
            lingering.remove(id)
            await change(id) { $0.completedAt = nil }
            if lastCompleted?.id == id { lastCompleted = nil }
            return
        }
        let at = clock()
        guard await change(id, { $0.completedAt = at }) else { return }
        completions += 1
        lingering.insert(id)
        lastCompleted = Completion(id: id, title: task.displayTitle)
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.lingerTime)
            self?.lingering.remove(id)
            try? await Task.sleep(for: Self.undoTime - Self.lingerTime)
            guard !Task.isCancelled, self?.lastCompleted?.id == id else { return }
            self?.lastCompleted = nil
        }
    }

    public func undoCompletion() async {
        guard let last = lastCompleted else { return }
        lastCompleted = nil
        undoTimer?.cancel()
        lingering.remove(last.id)
        await change(last.id) { $0.completedAt = nil }
    }

    /// Lets the Undo bar go before its time, as when the person dismisses it.
    public func dismissUndo() {
        lastCompleted = nil
        lingering.removeAll()
    }

    /// Changes one task in place and saves it.
    @discardableResult
    public func change(_ id: UUID, _ edit: (inout TaskItem) -> Void) async -> Bool {
        guard let old = tasks.first(where: { $0.id == id }) else { return false }
        var new = old
        edit(&new)
        guard new != old else { return true }
        new.noteChanges(from: old, at: clock())
        return await save(new, over: old)
    }

    /// Saves what an open editor changed since `base`, onto whatever the task is now.
    @discardableResult
    public func commit(_ edited: TaskItem, since base: TaskItem) async -> TaskItem? {
        guard let current = tasks.first(where: { $0.id == edited.id }) else { return nil }
        let new = current.applying(edited, since: base, at: clock())
        guard new != current else { return current }
        return await save(new, over: current) ? tasks.first { $0.id == edited.id } : nil
    }

    /// Plans a task for a day, Someday, or no day at all.
    public func schedule(_ id: UUID, _ choice: ScheduleChoice) async {
        await change(id) { task in
            switch choice {
            case .day(let day, let evening):
                task.when = day
                task.isEvening = evening
                if task.place == .someday || task.place == .inbox { task.place = .anytime }
            case .anytime:
                task.when = nil
                task.isEvening = false
                task.time = nil
                task.place = .anytime
            case .someday:
                task.when = nil
                task.isEvening = false
                task.time = nil
                task.place = .someday
            }
        }
    }

    public func delete(_ id: UUID) async {
        guard let vault else { return }
        do {
            try await vault.delete(id)
            tasks.removeAll { $0.id == id }
            lingering.remove(id)
            if lastCompleted?.id == id { lastCompleted = nil }
        } catch {
            notice = "That task couldn't be deleted. Try again."
        }
    }

    private func save(_ task: TaskItem, over old: TaskItem?) async -> Bool {
        guard let vault else { return false }
        do {
            let saved = try await vault.save(task, over: old)
            if let index = tasks.firstIndex(where: { $0.id == saved.id }) {
                tasks[index] = saved
            } else {
                tasks.append(saved)
            }
            return true
        } catch {
            notice = "That change couldn't be saved on this device. Try again."
            return false
        }
    }
}

/// Where a task can be planned.
public enum ScheduleChoice: Equatable, Sendable {
    case day(TaskDay, evening: Bool)
    case anytime
    case someday
}
