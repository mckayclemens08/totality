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
        /// What the Undo bar says instead of "Completed …", like "Eli replied, so the task is done".
        public var line: String? = nil
    }

    /// How long Undo stays after completing a task.
    public static let undoTime = Duration.seconds(5)
    /// How long a completed task stays ticked in its list before it slides away to the Logbook.
    public static let lingerTime = Duration.milliseconds(700)

    public private(set) var phase = Phase.loading
    public private(set) var tasks: [TaskItem] = [] {
        didSet { remindersNeedPlanning() }
    }
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
    /// Modules that say when someone replied, for tasks waiting on a reply (step 4).
    @ObservationIgnored public var replyWatchers: [any ReplyWatcher] = []
    /// Opens a task's source in its own module. The app does it, since Tasks can't reach other modules.
    @ObservationIgnored public var onOpenSource: ((TaskSource) -> Void)?
    /// Whether a task's source is gone, asked of its own module. Nil means nobody can tell.
    @ObservationIgnored public var sourceGone: ((TaskSource) async -> Bool)?
    @ObservationIgnored private let vault: TaskVault?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var undoTimer: Task<Void, Never>?
    @ObservationIgnored private var deleteTimer: Task<Void, Never>?

    /// Rings reminders on this iPhone. Nil in tests and previews, where nothing rings.
    @ObservationIgnored public var reminderCenter: (any TaskReminderScheduling)?
    /// Complete and Snooze from notifications, waiting for Tasks to open.
    @ObservationIgnored public var actionQueue: ReminderActionQueue?
    @ObservationIgnored private var planTimer: Task<Void, Never>?
    /// Whether reminders can ring here, for the reminders-off notices.
    public private(set) var reminderAccess = ReminderAccess()

    /// Deleted a moment ago, still held here for Undo.
    public private(set) var pendingDelete: PendingDelete?
    /// How long Undo stays after deleting. Then the delete is for good (owner, 2026-11-18). Tests shorten it.
    @ObservationIgnored public var deleteUndoTime = Duration.seconds(5)

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
            // What's waiting out its Undo stays hidden, though it's still on the device.
            let held = pendingDelete.map { Set($0.tasks.map(\.id) + $0.lists.map(\.id)) } ?? []
            tasks = listing.tasks.filter { !held.contains($0.id) }
            lists = listing.lists.filter { !held.contains($0.id) }
            unreadable = listing.unreadable
            phase = .ready
        } catch {
            phase = .failed
        }
        await applyQueuedActions()
        await planReminders()
        await loadEvents()
        await checkReplies()
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

    /// What the home tile shows: today's tasks first, then what's overdue and due next.
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
    public func add(_ text: String, in bucket: TaskBucket, list: UUID? = nil, heading: UUID? = nil) async -> [TaskItem] {
        now = clock()
        let parsed = QuickAddParser.parseLines(text, now: now, calendar: calendar)
        var order = (tasks.map(\.order).max() ?? 0) + 1
        var added: [TaskItem] = []
        for item in parsed {
            var task = item.task(
                defaultPlace: list == nil ? Self.place(for: bucket) : .anytime, defaultWhen: bucket == .today ? today : nil,
                order: order, now: now
            )
            if let list {
                task.listID = list
                task.headingID = heading
            }
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
            await unfinish(id)
            if lastCompleted?.id == id { lastCompleted = nil }
            return
        }
        let at = clock()
        guard await finish(id, at: at) else { return }
        completions += 1
        showUndo(Completion(id: id, title: task.displayTitle))
    }

    /// Keeps a just-completed task ticked in place for a moment, with Undo for a few seconds.
    func showUndo(_ completion: Completion) {
        let id = completion.id
        lingering.insert(id)
        lastCompleted = completion
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
        await unfinish(last.id)
        await keepWaiting(last.id)
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

/// Something deleted a moment ago, which Undo can still bring back.
public struct PendingDelete: Equatable, Sendable {
    public let tasks: [TaskItem]
    public let lists: [TaskList]
    /// When it goes for good.
    public let until: Date

    /// "3 tasks deleted", "“Hegel paper” deleted".
    public let title: String
}

/// Where a task can be moved: one of the fixed lists, or a project or area.
public enum TaskDestination: Hashable, Sendable {
    case bucket(TaskBucket)
    case list(UUID, heading: UUID? = nil)
}

// MARK: - Step 2: areas, projects, smart lists, moving, several at once, and undoable delete

extension TasksModel {
    public var areas: [TaskList] { ListRules.areas(in: lists) }
    public var smartLists: [TaskList] { ListRules.smartLists(in: lists) }

    public func list(_ id: UUID?) -> TaskList? {
        guard let id else { return nil }
        return lists.first { $0.id == id }
    }

    public func projects(in area: UUID?, status: TaskList.Status? = .active) -> [TaskList] {
        ListRules.projects(in: area, from: lists, status: status)
    }

    public func sections(of project: TaskList) -> [ProjectSection] {
        ListRules.sections(of: project, from: tasks)
    }

    public func projectProgress(of project: TaskList) -> ListProgress {
        ListRules.progress(of: project, from: tasks)
    }

    public func nextTask(in project: TaskList) -> TaskItem? {
        ListRules.nextTask(in: project, from: tasks)
    }

    public func looseTasks(in area: TaskList) -> [TaskItem] {
        ListRules.looseTasks(in: area, from: tasks)
    }

    public func tasks(matching rules: SmartRules) -> [TaskItem] {
        ListRules.tasks(matching: rules, from: tasks, lists: lists, today: today, in: calendar)
    }

    /// The tags in use, for a smart list's rule.
    public var allTags: [String] {
        Array(Set(tasks.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Makes an area, project or smart list. Returns it, or nil if it couldn't be saved.
    @discardableResult
    public func addList(
        name: String, kind: TaskList.Kind, area: UUID? = nil, deadline: TaskDay? = nil, rules: SmartRules? = nil,
        isPinned: Bool = false
    ) async -> TaskList? {
        let now = clock()
        let order = (lists.filter { $0.kind == kind }.map(\.order).max() ?? 0) + 1
        let list = TaskList(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, areaID: kind == .project ? area : nil,
            deadline: kind == .project ? deadline : nil, rules: kind == .smart ? (rules ?? SmartRules()) : nil,
            isPinned: kind == .smart && isPinned, order: order, createdAt: now
        )
        return await save(list) ? list : nil
    }

    /// Changes one list in place and saves it. Lists keep the newer whole, so the edit time moves on.
    @discardableResult
    public func changeList(_ id: UUID, _ edit: (inout TaskList) -> Void) async -> Bool {
        guard let old = list(id) else { return false }
        var new = old
        edit(&new)
        guard new != old else { return true }
        new.updatedAt = max(clock(), old.updatedAt)
        return await save(new)
    }

    public func addHeading(_ title: String, to project: UUID) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await changeList(project) { $0.headings.append(TaskList.Heading(title: trimmed)) }
    }

    /// Removes a heading. Its tasks stay in the project, above the first heading.
    public func removeHeading(_ heading: UUID, from project: UUID) async {
        for task in tasks where task.listID == project && task.headingID == heading {
            await change(task.id) { $0.headingID = nil }
        }
        await changeList(project) { $0.headings.removeAll { $0.id == heading } }
    }

    private func save(_ list: TaskList) async -> Bool {
        guard let vault else { return false }
        do {
            try await vault.save(list)
            if let index = lists.firstIndex(where: { $0.id == list.id }) {
                lists[index] = list
            } else {
                lists.append(list)
            }
            return true
        } catch {
            notice = "That change couldn't be saved on this device. Try again."
            return false
        }
    }

    // MARK: Moving

    /// Moves tasks to a list. Today plans them for today; Inbox takes them out of any project.
    public func move(_ ids: some Sequence<UUID>, to destination: TaskDestination) async {
        let today = today
        for id in ids {
            await change(id) { task in
                switch destination {
                case .bucket(.inbox):
                    task.place = .inbox
                    task.listID = nil
                    task.headingID = nil
                    task.when = nil
                    task.isEvening = false
                case .bucket(.today):
                    task.when = today
                    if task.place != .anytime { task.place = .anytime }
                case .bucket(.someday):
                    task.place = .someday
                    task.when = nil
                    task.isEvening = false
                    task.time = nil
                case .bucket(.anytime):
                    task.place = .anytime
                    task.when = nil
                    task.isEvening = false
                    task.time = nil
                case .bucket(.upcoming), .bucket(.logbook):
                    break
                case let .list(list, heading):
                    task.listID = list
                    task.headingID = heading
                    if task.place == .inbox { task.place = .anytime }
                }
            }
        }
    }

    /// Puts a dragged task just above another, taking its heading when they share a project.
    public func place(_ id: UUID, before target: UUID, in shown: [TaskItem]) async {
        guard id != target, let index = shown.firstIndex(where: { $0.id == target }) else { return }
        let above = shown[..<index].last { $0.id != id }
        let order = above.map { ($0.order + shown[index].order) / 2 } ?? shown[index].order - 1
        let targetTask = shown[index]
        await change(id) { task in
            task.order = order
            if task.listID == targetTask.listID, task.listID != nil { task.headingID = targetTask.headingID }
        }
    }

    // MARK: Several at once

    public func complete(_ ids: some Sequence<UUID>) async {
        let at = clock()
        for id in ids where !isDone(id) {
            await finish(id, at: at)
        }
        completions += 1
    }

    public func schedule(_ ids: some Sequence<UUID>, _ choice: ScheduleChoice) async {
        for id in ids { await schedule(id, choice) }
    }

    public func addTag(_ tag: String, to ids: some Sequence<UUID>) async {
        let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
        guard !clean.isEmpty else { return }
        for id in ids {
            await change(id) { task in
                if !task.tags.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) { task.tags.append(clean) }
            }
        }
    }

    // MARK: Undoable delete

    /// Deletes tasks and lists with no question asked. They vanish at once, Undo can bring them back for
    /// a few seconds, and then they're gone for good. Deleting an area or project takes everything in it.
    public func delete(tasks ids: Set<UUID>, lists listIDs: Set<UUID> = []) async {
        await finishPendingDelete()
        var goneLists = listIDs
        for area in lists where listIDs.contains(area.id) && area.kind == .area {
            goneLists.formUnion(lists.filter { $0.areaID == area.id }.map(\.id))
        }
        let heldLists = lists.filter { goneLists.contains($0.id) }
        let heldTasks = tasks.filter { ids.contains($0.id) || ($0.listID.map(goneLists.contains) ?? false) }
        guard !heldLists.isEmpty || !heldTasks.isEmpty else { return }
        let held = Set(heldTasks.map(\.id))
        tasks.removeAll { held.contains($0.id) }
        lists.removeAll { goneLists.contains($0.id) }
        lingering.subtract(held)
        if let last = lastCompleted, held.contains(last.id) { lastCompleted = nil }
        let wait = deleteUndoTime
        let title: String
        if listIDs.count == 1, let named = heldLists.first(where: { listIDs.contains($0.id) }) {
            title = "“\(named.displayName)” deleted"
        } else if !listIDs.isEmpty {
            title = "\(listIDs.count) lists deleted"
        } else {
            title = heldTasks.count == 1 ? "1 task deleted" : "\(heldTasks.count) tasks deleted"
        }
        pendingDelete = PendingDelete(
            tasks: heldTasks, lists: heldLists, until: clock().addingTimeInterval(Self.seconds(wait)), title: title
        )
        deleteTimer?.cancel()
        deleteTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.finishPendingDelete()
        }
    }

    /// Brings back what was just deleted.
    public func undoDelete() {
        guard let pending = pendingDelete else { return }
        deleteTimer?.cancel()
        pendingDelete = nil
        tasks.append(contentsOf: pending.tasks)
        lists.append(contentsOf: pending.lists)
    }

    /// Makes the delete permanent now, as when its time runs out or the next delete starts.
    public func finishPendingDelete() async {
        guard let pending = pendingDelete, let vault else { return }
        deleteTimer?.cancel()
        pendingDelete = nil
        var failed = false
        for id in pending.tasks.map(\.id) + pending.lists.map(\.id) {
            do { try await vault.delete(id) } catch { failed = true }
        }
        if failed {
            notice = "Some of that couldn't be deleted on this device. It's back in place."
            await load()
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

// MARK: - Step 3: repeats and reminders

extension TasksModel {
    /// Ticks a task off. A repeating one leaves its next copy behind, on the next day it falls on.
    @discardableResult
    func finish(_ id: UUID, at: Date) async -> Bool {
        guard let task = tasks.first(where: { $0.id == id }), !task.isCompleted else { return false }
        let following = TaskRepeats.following(task, completedAt: at, in: calendar)
        let done = await change(id) { task in
            task.completedAt = at
            task.snoozedUntil = nil
            // The rule moves on to the copy, so the finished one in the Logbook doesn't repeat too.
            if following != nil { task.repeatRule = nil }
        }
        guard done else { return false }
        if let following, !tasks.contains(where: { $0.id == following.id }) {
            _ = await save(following, over: nil)
        }
        return true
    }

    /// Brings a finished task back. If it left a copy that's still waiting, the copy goes and the rule
    /// comes back to this one.
    func unfinish(_ id: UUID) async {
        guard tasks.contains(where: { $0.id == id }) else { return }
        let following = tasks.first { candidate in
            guard !candidate.isCompleted, candidate.repeatRule != nil, let day = TaskRepeats.anchor(of: candidate) else { return false }
            return TaskRepeats.followingID(of: id, on: day) == candidate.id
        }
        await change(id) { task in
            task.completedAt = nil
            if var rule = following?.repeatRule {
                rule.done = max(0, rule.done - 1)
                task.repeatRule = rule
            }
        }
        if let following, let vault {
            try? await vault.delete(following.id)
            tasks.removeAll { $0.id == following.id }
        }
    }

    /// Sets, changes or (with nil) stops a task's repeat. A task with no day starts on the rule's first.
    public func setRepeat(_ id: UUID, _ rule: RepeatRule?) async {
        await change(id) { task in
            task.repeatRule = rule
            if let rule, task.when == nil, task.deadline == nil {
                task.when = rule.start
                if task.place != .anytime { task.place = .anytime }
            }
        }
    }

    /// Passes over the occurrence that's due; the task moves to the next one.
    public func skipNext(_ id: UUID) async {
        guard let task = tasks.first(where: { $0.id == id }), let moved = TaskRepeats.skippingNext(task, in: calendar) else { return }
        await change(id) { task in
            task.when = moved.when
            task.deadline = moved.deadline
            task.reminders = moved.reminders
            task.repeatRule = moved.repeatRule
            task.snoozedUntil = nil
        }
    }

    /// Crosses a coming date out, or brings it back.
    public func toggleSkip(_ id: UUID, on day: TaskDay) async {
        await change(id) { task in
            guard var rule = task.repeatRule else { return }
            if rule.skipped.contains(day) { rule.skipped.remove(day) } else { rule.skipped.insert(day) }
            task.repeatRule = rule
        }
    }

    public func addReminder(_ id: UUID, _ kind: TaskReminder.Kind) async {
        await change(id) { $0.reminders.append(TaskReminder(kind: kind)) }
        await askForAccess(place: { if case .place = kind { true } else { false } }())
    }

    public func replaceReminder(_ id: UUID, _ reminder: TaskReminder) async {
        await change(id) { task in
            if let index = task.reminders.firstIndex(where: { $0.id == reminder.id }) {
                task.reminders[index] = reminder
            } else {
                task.reminders.append(reminder)
            }
        }
        await askForAccess(place: reminder.isPlace)
    }

    public func removeReminder(_ id: UUID, _ reminder: UUID) async {
        await change(id) { $0.reminders.removeAll { $0.id == reminder } }
    }

    public func setNagging(_ id: UUID, _ nagging: Nagging?) async {
        await change(id) { $0.nagging = nagging }
        if nagging != nil { await askForAccess(place: false) }
    }

    public func snooze(_ id: UUID, _ snooze: ReminderAction.Snooze) async {
        let until = snooze.until(from: clock(), in: calendar)
        await change(id) { $0.snoozedUntil = until }
    }

    /// Asks iOS for what a new reminder needs, the first time only. Location asks for Always, and only
    /// once a place reminder is made (owner, 2026-11-18).
    func askForAccess(place: Bool) async {
        guard let reminderCenter else { return }
        var access = await reminderCenter.access()
        if access.notifications == .notAsked { _ = await reminderCenter.requestNotifications() }
        if place, access.location == .notAsked || access.location == .whileUsing { await reminderCenter.requestAlwaysLocation() }
        access = await reminderCenter.access()
        reminderAccess = access
    }

    public func refreshReminderAccess() async {
        guard let reminderCenter else { return }
        reminderAccess = await reminderCenter.access()
    }

    /// Applies Complete and Snooze taken from notifications while Tasks was closed or in the background.
    public func applyQueuedActions() async {
        guard phase == .ready, let actionQueue else { return }
        for action in actionQueue.drain() {
            guard let task = tasks.first(where: { $0.id == action.taskID }) else { continue }
            switch action.kind {
            case .complete:
                if !task.isCompleted { await finish(task.id, at: action.at) }
            case .snooze(let until):
                if !task.isCompleted { await change(task.id) { $0.snoozedUntil = until } }
            }
        }
    }

    fileprivate func remindersNeedPlanning() {
        guard reminderCenter != nil, phase == .ready else { return }
        planTimer?.cancel()
        planTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.planReminders()
        }
    }

    /// Sets every reminder on the iPhone again from the tasks as they are now.
    public func planReminders() async {
        guard let reminderCenter, phase == .ready else { return }
        let names = Dictionary(lists.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let now = clock()
        let planned = TaskReminderPlanner.plan(tasks, listNames: names, now: now, calendar: calendar)
        let places = TaskReminderPlanner.places(tasks, calendar: calendar)
        await reminderCenter.replace(with: planned, places: places)
        reminderAccess = await reminderCenter.access()
    }
}
