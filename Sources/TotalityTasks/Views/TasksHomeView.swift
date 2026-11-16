import SwiftUI
import TotalityCore
import TotalityUI

/// Tasks' front screen: the person's lists with their counts, and quick add.
public struct TasksHomeView: View {
    @Bindable private var model: TasksModel
    private let onClose: (() -> Void)?
    @State private var path: [TaskBucket] = []
    @State private var expanded: UUID?
    @State private var addingTo: TaskBucket?

    public init(model: TasksModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack(path: $path) {
            front
                .background(theme.bg.color)
                .edgeSwipeBack(onClose)
                .navigationDestination(for: TaskBucket.self) { bucket in
                    TaskListView(model: model, bucket: bucket, expanded: $expanded)
                }
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .cancellationAction) {
                            ToolbarIcon("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
                        }
                    }
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #else
                .navigationTitle("Tasks")
                #endif
        }
        .tint(theme.accent.color)
        .overlay(alignment: .bottomTrailing) {
            if model.phase == .ready {
                QuickAddButton { addingTo = path.last ?? .inbox }
                    .padding(Space.s5)
            }
        }
        .overlay(alignment: .bottom) {
            if let last = model.lastCompleted {
                UndoBar(title: last.title, onUndo: { Task { await model.undoCompletion() } }, onDismiss: model.dismissUndo)
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s5 + Space.s7)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: model.lastCompleted)
        .sensoryFeedback(.success, trigger: model.completions)
        .sheet(item: $addingTo) { bucket in
            QuickAddView(model: model, bucket: bucket) { addingTo = nil }
        }
        .alert("Tasks", isPresented: noticeShown) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .task {
            await model.load()
            takeRequests()
        }
        .onChange(of: model.requestedTask) { takeRequests() }
        .onChange(of: model.requestedQuickAdd) { takeRequests() }
        .onChange(of: path) {
            if path.isEmpty { expanded = nil }
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
            path = [TaskRules.bucket(of: task, today: model.today)]
            expanded = id
        }
        if model.requestedQuickAdd {
            model.requestedQuickAdd = false
            addingTo = .inbox
        }
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
            ScrollView {
                TasksFront(model: model)
            }
            .pullsToRefresh(with: model.refresher)
        }
    }
}

/// What the front screen holds: the lists, with their counts.
struct TasksFront: View {
    let model: TasksModel

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s5) {
            Text("Tasks")
                .font(Typeface.display)
                .foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            RefreshStatusLine(model.refresher)
            if model.unreadable > 0 {
                Label(
                    model.unreadable == 1 ? "1 task can't be opened with this device's key." : "\(model.unreadable) tasks can't be opened with this device's key.",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            }
            BucketCard(model: model, buckets: [.inbox])
            BucketCard(model: model, buckets: [.today, .upcoming, .anytime, .someday])
            BucketCard(model: model, buckets: [.logbook])
        }
        .padding(.horizontal, Space.s4)
        .padding(.bottom, Space.s8 + Space.s5)
    }
}

/// A raised card of lists, each with its count.
private struct BucketCard: View {
    let model: TasksModel
    let buckets: [TaskBucket]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(buckets) { bucket in
                NavigationLink(value: bucket) {
                    BucketRow(model: model, bucket: bucket)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Space.s2)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

private struct BucketRow: View {
    let model: TasksModel
    let bucket: TaskBucket

    var body: some View {
        let theme = Theme.current
        let count = bucket == .logbook ? 0 : model.count(bucket)
        let overdue = bucket == .today ? model.overdue : 0
        HStack(spacing: Space.s3) {
            Image(systemName: bucket.systemImage)
                .font(Typeface.body)
                .foregroundStyle(bucket == .today ? theme.accent.color : theme.textSecondary.color)
                .frame(width: Space.s5)
                .accessibilityHidden(true)
            Text(bucket.name)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
            Spacer()
            if overdue > 0 {
                Text("\(overdue)")
                    .font(Typeface.callout)
                    .monospacedDigit()
                    .foregroundStyle(theme.danger.color)
                    .accessibilityLabel("\(overdue) overdue")
            }
            if count > 0 {
                Text("\(count)")
                    .font(Typeface.callout)
                    .monospacedDigit()
                    // The one accent is Today's count.
                    .foregroundStyle(bucket == .today ? theme.accent.color : theme.textSecondary.color)
            }
            Image(systemName: "chevron.right")
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The + that opens quick add. With Today's count, it's the only thing in the accent colour.
struct QuickAddButton: View {
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Image(systemName: "plus")
                .font(Typeface.title)
                .foregroundStyle(theme.accentOn.color)
                .frame(width: Space.s7 + Space.s2, height: Space.s7 + Space.s2)
                .background(Circle().fill(theme.accent.color))
                .shadow(color: theme.shadowDark.color, radius: Space.s3, x: Space.s1, y: Space.s1)
                .shadow(color: theme.shadowLight.color, radius: Space.s3, x: -Space.s1, y: -Space.s1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New task")
        .keyboardShortcut("n", modifiers: .command)
    }
}

/// "Completed …  Undo", for a few seconds after a tick.
struct UndoBar: View {
    let title: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Text("Completed “\(title)”")
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
