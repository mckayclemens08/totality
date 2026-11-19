import SwiftUI
import TotalityCore
import TotalityUI

extension ModuleID {
    /// How a task's link names where it came from.
    var sourceName: String {
        switch self {
        case .mail: "Mail"
        case .messages: "Messages"
        case .photos: "Photos"
        case .reader: "Reader"
        case .web: "Web"
        case .calendar: "Calendar"
        default: rawValue.capitalized
        }
    }

    var sourceImage: String {
        switch self {
        case .mail: "envelope"
        case .messages: "bubble.left"
        case .photos: "photo"
        case .reader: "book"
        case .web: "globe"
        case .calendar: "calendar"
        default: "link"
        }
    }
}

/// "From": the quote, if there is one, and the link back to where the task came from (step 4 board, task
/// detail). A source that's gone says so, with Remove, and the task keeps its title (decision 6).
struct SourceCard: View {
    let model: TasksModel
    let task: TaskItem
    let source: TaskSource
    @State private var isGone = false

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("From")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Space.s3) {
                if let quote = source.quote, !isGone {
                    Text("“\(quote)”")
                        .font(Typeface.callout.weight(.regular))
                        .italic()
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(6)
                        .accessibilityLabel("Quote: \(quote)")
                }
                HStack(spacing: Space.s3) {
                    Image(systemName: source.module.sourceImage)
                        .font(Typeface.callout)
                        .foregroundStyle(isGone ? theme.textSecondary.color : theme.accent.color)
                        .frame(width: Space.s6)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.s1 / 2) {
                        Text(isGone ? "\(source.module.sourceName) item no longer available" : label)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                        Text(isGone ? "The task keeps its title" : source.title)
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(2)
                    }
                    Spacer(minLength: Space.s2)
                    if isGone {
                        Button("Remove") { Task { await model.removeSource(of: task.id) } }
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textSecondary.color)
                            .accessibilityLabel("Remove the link")
                    } else {
                        Button("Open") { model.openSource(of: task) }
                            .font(Typeface.callout)
                            .foregroundStyle(theme.accent.color)
                            .accessibilityLabel("Open in \(source.module.sourceName)")
                    }
                }
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .opacity(isGone ? 0.75 : 1)
        }
        .task(id: source) {
            isGone = await model.sourceGone?(source) ?? false
        }
    }

    private var label: String {
        [source.module.sourceName, source.detail].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The Waiting list: tasks waiting for a reply, which tick themselves off when one comes (decision 1).
struct WaitingScreen: View {
    @Bindable var model: TasksModel
    let onBack: () -> Void
    @State private var expanded: UUID?
    @State private var scheduling: ScheduleTarget?

    var body: some View {
        let theme = Theme.current
        let list = model.waitingList
        VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                HeaderButton("Back", systemImage: "chevron.left", action: onBack)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Metric.headerButton)
            .padding(.horizontal, Space.s4)
            .padding(.top, Space.s2)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    ScreenTitle("Waiting", subtitle: "Ticks itself off when someone replies")
                    if list.open.isEmpty, list.doneToday.isEmpty {
                        Text("Nothing is waiting. In Mail, choose Add as waiting for reply on a message you sent.")
                            .font(Typeface.callout.weight(.regular))
                            .foregroundStyle(theme.textSecondary.color)
                            .padding(.top, Space.s4)
                    }
                    ForEach(list.open) { task in row(task) }
                    if !list.doneToday.isEmpty {
                        Text("Done today")
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textSecondary.color)
                            .padding(.top, Space.s3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(list.doneToday) { task in row(task).opacity(0.6) }
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.bottom, Space.s8)
            }
        }
        .background(theme.bg.color)
        .edgeSwipeBack(onBack)
        .sheet(item: $scheduling) { target in
            ScheduleSheet(model: model, target: target) { scheduling = nil }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            TaskRow(
                model: model, task: task, bucket: .anytime, isExpanded: expanded == task.id,
                onTap: { withMotion(Motion.smooth) { expanded = expanded == task.id ? nil : task.id } },
                onSchedule: { scheduling = $0 }
            )
            if expanded != task.id, let line = model.waitingLine(for: task) {
                Label(line, systemImage: task.isCompleted ? "checkmark" : "hourglass")
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.textSecondary.color)
                    .padding(.leading, Space.s4)
            }
        }
    }
}
