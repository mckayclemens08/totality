import SwiftUI
import TotalityCore
import TotalityUI
import UniformTypeIdentifiers

/// Tasks' screen: Home, the list's big title, a pill for each list, and the list itself (redesign,
/// 2026-11-17). Today opens first, with its progress ring.
public struct TasksHomeView: View {
    /// Today first, as on the canvas, then the rest in their usual order.
    static let pillOrder: [TaskBucket] = [.today, .inbox, .upcoming, .anytime, .someday, .logbook]

    @Bindable private var model: TasksModel
    /// Shared lists and projects (step 6), where Messages runs.
    private let shared: SharedListsModel?
    @State private var openShared: SharedOpen?
    @State private var sharing: TaskList?
    private let onClose: (() -> Void)?
    @State private var bucket: TaskBucket = .today
    @State private var expanded: UUID?
    @State private var addingTo: TaskBucket?
    /// Every list at once, with areas, projects and smart lists (step 2).
    @State private var showsLists = false
    /// An area, project or smart list, open over the rest.
    @State private var openList: UUID?
    /// The built-in Waiting list, open over the rest (step 4).
    @State private var showsWaiting = false
    @State private var making: TaskList.Kind?
    @State private var selection = TaskSelection()
    @State private var selectionSheet: SelectionSheet?
    @AppStorage("tasks.splitToday") private var splitToday = false

    public init(model: TasksModel, shared: SharedListsModel? = nil, onClose: (() -> Void)? = nil) {
        self.model = model
        self.shared = shared
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            header
            front
        }
        .background(theme.bg.color)
        .edgeSwipeBack(onClose)
        .overlay(alignment: .bottomTrailing) {
            if model.phase == .ready, !selection.isOn, openList == nil, !showsWaiting {
                if showsLists {
                    Menu {
                        Button("New task", systemImage: "plus") { addingTo = .inbox }
                        Button("New project", systemImage: "circle") { making = .project }
                        Button("New area", systemImage: "square.stack") { making = .area }
                        Button("New smart list", systemImage: "line.3.horizontal.decrease") { making = .smart }
                    } label: {
                        AddMark()
                    }
                    .accessibilityLabel("New task, list, project or area")
                    .padding(Space.s4)
                } else {
                    AddButton("New task") { addingTo = bucket == .logbook ? .inbox : bucket }
                        .padding(Space.s4)
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        .overlay {
            if let id = openList {
                ListScreen(model: model, listID: id, onBack: closeList, onOpen: { openList = $0 }, onShare: shared?.isAvailable == true ? { startSharing($0) } : nil)
                    .id(id)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .motion(Motion.smooth, value: openList)
        .overlay {
            if showsWaiting {
                WaitingScreen(model: model) { showsWaiting = false }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
            if let open = openShared, let shared {
                SharedListScreen(shared: shared, model: model, room: open.room, onBack: { openShared = nil }, openTask: open.task)
                    .id(open)
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }
        }
        .motion(Motion.smooth, value: showsWaiting)
        .motion(Motion.smooth, value: openShared)
        .sheet(item: $sharing) { list in
            if let shared {
                ShareSheet(shared: shared, target: .list(list, model.tasks.filter { $0.listID == list.id })) { room in
                    sharing = nil
                    guard let room else { return }
                    openList = nil
                    openShared = SharedOpen(room: room, task: nil)
                    // The list now lives in its encrypted room; the private copy goes.
                    Task {
                        await model.delete(tasks: [], lists: [list.id])
                        await model.finishPendingDelete()
                    }
                }
            }
        }
        .alert("Shared lists", isPresented: sharedNoticeShown) {
            Button("OK", role: .cancel) { shared?.notice = nil }
        } message: {
            Text(shared?.notice ?? "")
        }
        .overlay(alignment: .top) {
            if selection.isOn {
                SelectionHeader(selection: selection, visible: visibleIDs)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if selection.isOn {
                SelectionBar(model: model, selection: selection, sheet: $selectionSheet)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if selection.showsTray {
                DragTray(model: model, selection: selection)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(Motion.snappy, value: selection.isOn)
        .motion(Motion.snappy, value: selection.showsTray)
        .onDrop(of: [.plainText, .utf8PlainText], delegate: DragWatcher(selection: selection))
        .sensoryFeedback(.selection, trigger: selection.ticks)
        .environment(\.taskSelection, selection)
        .tint(theme.accent.color)
        .overlay(alignment: .bottom) {
            if let pending = model.pendingDelete {
                DeleteUndoBar(pending: pending, onUndo: model.undoDelete)
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, selection.isOn ? Space.s8 + Space.s6 : Space.s5 + Metric.addButton)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let last = model.lastCompleted {
                UndoBar(title: last.title, line: last.line, onUndo: { Task { await model.undoCompletion() } }, onDismiss: model.dismissUndo)
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s5 + Metric.addButton)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(Motion.smooth, value: model.lastCompleted)
        .motion(Motion.smooth, value: model.pendingDelete)
        .sheet(item: $making) { kind in
            if kind == .smart {
                SmartListEditor(model: model) { making = nil }
            } else {
                NewListSheet(model: model, kind: kind) { made in
                    making = nil
                    if let made { openList = made }
                }
            }
        }
        .sheet(item: $selectionSheet) { sheet in
            let ids = selection.ids
            let done = {
                selectionSheet = nil
                selection.end()
            }
            switch sheet {
            case .move: MoveSheet(model: model, ids: ids, onDone: done)
            case .tag: TagSheet(model: model, ids: ids, onDone: done)
            case .date:
                if let first = ids.first {
                    ScheduleSheet(model: model, target: ScheduleTarget(id: first, kind: .when, others: Array(ids.subtracting([first]))), onDone: done)
                }
            }
        }
        .sensoryFeedback(.success, trigger: model.completions)
        .sheet(item: $addingTo) { bucket in
            QuickAddView(model: model, bucket: bucket) { addingTo = nil }
        }
        .setAlarmSheet(Binding(get: { model.alarmDraft }, set: { model.alarmDraft = $0 }), maker: model.alarmMaker) { made in
            model.notice = made.line
        }
        .alert("Tasks", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .task {
            await model.load()
            takeRequests()
            if let shared {
                model.refresher.add("shared lists") { await shared.refresh(); return .done }
                await shared.refresh()
            }
        }
        .onChange(of: model.requestedTask) { takeRequests() }
        .onChange(of: model.requestedQuickAdd) { takeRequests() }
        .onChange(of: bucket) {
            expanded = nil
            selection.end()
        }
        .onChange(of: showsLists) { selection.end() }
        .onChange(of: openList) { selection.end() }
        .onDisappear {
            Task { await model.finishPendingDelete() }
        }
    }

    private var sharedNoticeShown: Binding<Bool> {
        Binding(get: { shared?.notice != nil }, set: { if !$0 { shared?.notice = nil } })
    }

    /// Opens the Share sheet for a project, or an area with no projects in it.
    private func startSharing(_ id: UUID) {
        guard let list = model.list(id) else { return }
        if list.kind == .area, !model.projects(in: id, status: nil).isEmpty {
            model.notice = "Move this area's projects out first, or share each project on its own."
            return
        }
        sharing = list
    }

    private func closeList() {
        openList = nil
    }

    /// The tasks on screen now, for Select all.
    private var visibleIDs: [UUID] {
        if let id = openList, let list = model.list(id) {
            switch list.kind {
            case .project: return model.sections(of: list).flatMap(\.tasks).map(\.id)
            case .area: return model.looseTasks(in: list).map(\.id)
            case .smart: return model.tasks(matching: list.rules ?? SmartRules()).map(\.id)
            }
        }
        guard !showsLists else { return [] }
        switch bucket {
        case .upcoming:
            return (model.upcoming.flatMap { $0.tasks + $0.deadlines } + model.later).map(\.id)
        case .logbook:
            return model.logbook().flatMap(\.tasks).map(\.id)
        default:
            return model.tasks(in: bucket).map(\.id)
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    /// Opens what home search or the tile asked for: a task, in its list and open, or quick add.
    private func takeRequests() {
        guard model.phase == .ready else { return }
        if let id = model.requestedTask, let task = model.tasks.first(where: { $0.id == id }) {
            model.requestedTask = nil
            bucket = TaskRules.bucket(of: task, today: model.today)
            showsLists = false
            openList = nil
            expanded = id
        }
        if model.requestedQuickAdd {
            model.requestedQuickAdd = false
            addingTo = .inbox
        }
    }

    /// Home and Today's options, the list's big title, and the pills.
    private var header: some View {
        let ready = model.phase == .ready
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                if let onClose {
                    HeaderButton("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
                }
                Spacer(minLength: 0)
                if ready, bucket == .today, !showsLists {
                    HeaderMenu("Today options", systemImage: "ellipsis") {
                        Toggle("Split into morning, afternoon and evening", isOn: $splitToday)
                    }
                }
            }
            .frame(minHeight: Metric.headerButton)
            ScreenTitle(ready ? (showsLists ? "Lists" : bucket.name) : "Tasks")
            if ready {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s2) {
                        FilterPill("Lists", isSelected: showsLists) {
                            withMotion(Motion.snappy) { showsLists = true }
                        }
                        ForEach(Self.pillOrder) { item in
                            FilterPill(pillTitle(item), isSelected: !showsLists && bucket == item) {
                                withMotion(Motion.snappy) {
                                    showsLists = false
                                    bucket = item
                                }
                            }
                            .accessibilityLabel(pillLabel(item))
                        }
                    }
                    // Room for the shadow pair, which a scroll view would clip.
                    .padding(Space.s2)
                }
                .padding(.horizontal, -Space.s2)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }

    /// "Today · 4": Inbox and Today show what's in them, as the old list of lists did.
    private func pillTitle(_ item: TaskBucket) -> String {
        let count = item == .inbox || item == .today ? model.count(item) : 0
        return count > 0 ? "\(item.name) · \(count)" : item.name
    }

    private func pillLabel(_ item: TaskBucket) -> String {
        var parts = [item.name]
        if item == .inbox || item == .today, model.count(item) > 0 { parts.append("\(model.count(item)) tasks") }
        if item == .today, model.overdue > 0 { parts.append("\(model.overdue) overdue") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var front: some View {
        switch model.phase {
        case .loading:
            ProgressView("Opening your tasks")
                .font(Typeface.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            TasksMessage(
                systemImage: "exclamationmark.triangle",
                title: "Your tasks didn't open",
                detail: "This device's storage couldn't be read. Close Tasks and try again. Nothing has been changed."
            )
            .pullsToRefresh(with: model.refresher)
        case .ready:
            if showsLists {
                ListsOverview(
                    model: model,
                    onBucket: { item in withMotion(Motion.snappy) { showsLists = false; bucket = item } },
                    onList: { openList = $0 },
                    onNew: { making = $0 },
                    shared: shared,
                    onShared: { openShared = SharedOpen(room: $0, task: nil) },
                    onWaiting: { showsWaiting = true }
                )
            } else {
                TaskListView(model: model, bucket: bucket, expanded: $expanded, shared: shared) { room, task in
                    openShared = SharedOpen(room: room, task: task)
                }
                    .id(bucket)
            }
        }
    }
}

/// "Completed …  Undo", for a few seconds after a tick.
struct UndoBar: View {
    let title: String
    var line: String?
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Text(line ?? "Completed “\(title)”")
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            Spacer()
            Button("Undo", action: onUndo)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .neumorphic(.raised, in: Capsule())
        .onTapGesture(perform: onDismiss)
    }
}

/// A full-screen message, for when Tasks can't open.
struct TasksMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(spacing: Space.s3) {
                Image(systemName: systemImage)
                    .font(Typeface.display)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Typeface.title)
                    .foregroundStyle(theme.textPrimary.color)
                Text(detail)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
            }
            .padding(Space.s6)
            .frame(maxWidth: .infinity)
            .padding(.top, Space.s8)
        }
    }
}

/// A shared list open over Tasks, maybe at one of its tasks.
struct SharedOpen: Hashable {
    let room: String
    let task: UUID?
}
