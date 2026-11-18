import SwiftUI
import TotalityCore
import TotalityUI

/// Where a + adds into: a project or area, and a heading in it.
struct AddTarget: Identifiable, Equatable {
    let list: UUID
    var heading: UUID?

    var id: String { "\(list)-\(heading?.uuidString ?? "")" }
}

/// One area, project or smart list, opened from Lists (step 2 canvas, approved 2026-11-18).
struct ListScreen: View {
    @Bindable var model: TasksModel
    let listID: UUID
    let onBack: () -> Void
    let onOpen: (UUID) -> Void
    @State private var expanded: UUID?
    @State private var scheduling: ScheduleTarget?
    @State private var adding: AddTarget?
    @State private var editingRules = false
    @State private var newProject = false
    @State private var settingDeadline = false
    @State private var renaming: Rename?
    @State private var areaFilter = TaskList.Status.active
    @Environment(\.taskSelection) private var selection

    /// Renaming the list, or one of a project's headings, or adding a heading.
    private struct Rename: Identifiable {
        enum Kind { case list, heading(UUID), newHeading }
        let id = UUID()
        let kind: Kind
        var text: String
    }

    var body: some View {
        let theme = Theme.current
        Group {
            if let list = model.list(listID) {
                VStack(spacing: 0) {
                    header(list)
                    content(list)
                }
                .overlay(alignment: .bottomTrailing) {
                    if list.kind != .smart, !(selection?.isOn ?? false) {
                        AddButton("New task") { adding = AddTarget(list: list.id, heading: nil) }
                            .padding(Space.s4)
                    }
                }
                .sheet(isPresented: $editingRules) {
                    SmartListEditor(model: model, existing: list) { editingRules = false }
                }
                .sheet(isPresented: $newProject) {
                    NewListSheet(model: model, kind: .project, area: list.id) { made in
                        newProject = false
                        if let made { onOpen(made) }
                    }
                }
                .sheet(isPresented: $settingDeadline) {
                    DeadlineSheet(model: model, project: list) { settingDeadline = false }
                }
            } else {
                // Deleted, here or on another device.
                Color.clear.onAppear(perform: onBack)
            }
        }
        .background(theme.bg.color)
        .edgeSwipeBack(onBack)
        .sheet(item: $adding) { target in
            QuickAddView(model: model, bucket: .anytime, list: target.list, heading: target.heading) { adding = nil }
        }
        .sheet(item: $scheduling) { target in
            ScheduleSheet(model: model, target: target) { scheduling = nil }
        }
        .alert(renameTitle, isPresented: renameShown) {
            TextField("Name", text: Binding(get: { renaming?.text ?? "" }, set: { renaming?.text = $0 }))
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { saveRename() }
        }
    }

    // MARK: - Header

    private func header(_ list: TaskList) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                HeaderButton("Back", systemImage: "chevron.left", action: onBack)
                Spacer(minLength: 0)
                HeaderMenu("More", systemImage: "ellipsis") { menu(list) }
            }
            .frame(minHeight: Metric.headerButton)
            switch list.kind {
            case .project: projectTitle(list)
            case .area: areaTitle(list)
            case .smart: ScreenTitle(list.displayName, subtitle: rulesSummary(list))
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }

    @ViewBuilder private func menu(_ list: TaskList) -> some View {
        Button("Rename", systemImage: "pencil") { renaming = Rename(kind: .list, text: list.name) }
        switch list.kind {
        case .project:
            Button("Add a heading", systemImage: "text.badge.plus") { renaming = Rename(kind: .newHeading, text: "") }
            Button(list.deadline == nil ? "Set a deadline" : "Change the deadline", systemImage: "flag") { settingDeadline = true }
            Menu("Area", systemImage: "square.stack") {
                Picker("Area", selection: Binding(
                    get: { list.areaID },
                    set: { area in Task { await model.changeList(list.id) { $0.areaID = area } } }
                )) {
                    Text("No area").tag(UUID?.none)
                    ForEach(model.areas) { Text($0.displayName).tag(Optional($0.id)) }
                }
            }
            Picker("Status", selection: Binding(
                get: { list.status },
                set: { status in Task { await model.changeList(list.id) { $0.status = status } } }
            )) {
                ForEach(TaskList.Status.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        case .area:
            Button("New project here", systemImage: "plus.circle") { newProject = true }
        case .smart:
            Button("Edit rules", systemImage: "line.3.horizontal.decrease") { editingRules = true }
            Button(list.isPinned ? "Unpin from Lists" : "Pin to Lists", systemImage: list.isPinned ? "pin.slash" : "pin") {
                Task { await model.changeList(list.id) { $0.isPinned.toggle() } }
            }
        }
        Divider()
        Button(deleteTitle(list), systemImage: "trash", role: .destructive) {
            onBack()
            Task { await model.delete(tasks: [], lists: [list.id]) }
        }
    }

    private func deleteTitle(_ list: TaskList) -> String {
        switch list.kind {
        case .project: "Delete project and its tasks"
        case .area: "Delete area and everything in it"
        case .smart: "Delete smart list"
        }
    }

    private func projectTitle(_ project: TaskList) -> some View {
        let theme = Theme.current
        let progress = model.projectProgress(of: project)
        return HStack(spacing: Space.s4) {
            TotalityUI.ProgressRing(progress: progress.fraction, diameter: Space.s8 + Space.s5) {
                Text("\(progress.done)/\(progress.total)")
                    .font(Typeface.title)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, Space.s2)
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(project.displayName)
                    .font(Typeface.display)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Space.s2) {
                    if let area = model.list(project.areaID) { ListChip(text: area.displayName) }
                    if let deadline = project.deadline {
                        let near = model.today.days(to: deadline, in: model.calendar) <= TaskRules.deadlineNear
                        ListChip(text: "Due " + TaskText.day(deadline, today: model.today, in: model.calendar), tone: near ? .danger : .plain)
                    }
                    if project.status != .active { ListChip(text: project.status.name) }
                }
            }
        }
        .padding(.bottom, Space.s2)
    }

    private func areaTitle(_ area: TaskList) -> some View {
        let projects = model.projects(in: area.id, status: nil)
        let loose = model.looseTasks(in: area).count
        let finished = projects.filter { $0.status == .finished }.count
        let active = projects.filter { $0.status == .active }.count
        return VStack(alignment: .leading, spacing: Space.s3) {
            ScreenTitle(area.displayName, subtitle: [
                active == 1 ? "1 project" : "\(active) projects",
                loose == 1 ? "1 loose task" : "\(loose) loose tasks",
            ].joined(separator: " · "))
            HStack(spacing: Space.s2) {
                ForEach(TaskList.Status.allCases, id: \.self) { status in
                    FilterPill(status == .finished && finished > 0 ? "Finished · \(finished)" : status.name, isSelected: areaFilter == status) {
                        withMotion(Motion.snappy) { areaFilter = status }
                    }
                }
            }
            .padding(.vertical, Space.s1)
        }
    }

    private func rulesSummary(_ list: TaskList) -> String {
        let count = list.rules?.rules.count ?? 0
        guard count > 0 else { return "No rules yet" }
        if count == 1 { return "Matches 1 rule" }
        return list.rules?.match == .any ? "Matches any of \(count) rules" : "Matches all \(count) rules"
    }

    // MARK: - Content

    private func content(_ list: TaskList) -> some View {
        List {
            RefreshStatusLine(model.refresher).plainRow()
            switch list.kind {
            case .project: projectBody(list)
            case .area: areaBody(list)
            case .smart: smartBody(list)
            }
            Color.clear.frame(height: Metric.addButton + Space.s5).plainRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .motion(Motion.smooth, value: model.tasks.map(\.id))
        .motion(Motion.smooth, value: expanded)
        .pullsToRefresh(with: model.refresher)
    }

    @ViewBuilder private func projectBody(_ project: TaskList) -> some View {
        let sections = model.sections(of: project)
        if sections.allSatisfy(\.tasks.isEmpty) {
            EmptyProject(model: model, project: project, onAdd: { adding = AddTarget(list: project.id) }, onHeading: {
                renaming = Rename(kind: .newHeading, text: "")
            })
            .plainRow()
        }
        ForEach(sections) { section in
            if let heading = section.heading {
                HeadingRow(
                    title: heading.title, detail: section.tasks.isEmpty ? nil : "\(section.done) of \(section.tasks.count) done",
                    onAdd: { adding = AddTarget(list: project.id, heading: heading.id) },
                    onRename: { renaming = Rename(kind: .heading(heading.id), text: heading.title) },
                    onRemove: { Task { await model.removeHeading(heading.id, from: project.id) } }
                )
                .plainRow()
            }
            TaskRows(model: model, tasks: section.tasks, expanded: $expanded, scheduling: $scheduling, showsList: false)
        }
    }

    @ViewBuilder private func areaBody(_ area: TaskList) -> some View {
        let projects = model.projects(in: area.id, status: areaFilter)
        ForEach(projects) { project in
            ProjectCard(model: model, project: project) { onOpen(project.id) }
                .plainRow(vertical: Space.s2)
        }
        if projects.isEmpty, areaFilter != .active {
            Text(areaFilter == .finished ? "No finished projects yet." : "No projects parked for someday.")
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(Theme.current.textSecondary.color)
                .padding(.vertical, Space.s3)
                .plainRow()
        }
        if areaFilter == .active {
            let loose = model.looseTasks(in: area)
            if projects.isEmpty, loose.isEmpty {
                EmptyArea(onProject: { newProject = true }, onTask: { adding = AddTarget(list: area.id) }).plainRow()
            }
            if !loose.isEmpty {
                HeadingRow(title: "Loose tasks", detail: "\(loose.count)").plainRow()
                TaskRows(model: model, tasks: loose, expanded: $expanded, scheduling: $scheduling, showsList: false)
            }
        }
    }

    @ViewBuilder private func smartBody(_ list: TaskList) -> some View {
        let found = model.tasks(matching: list.rules ?? SmartRules())
        if found.isEmpty {
            VStack(spacing: Space.s3) {
                Text((list.rules?.rules.isEmpty ?? true) ? "Add a rule to fill this list." : "Nothing matches these rules right now.")
                    .font(Typeface.callout.weight(.regular))
                    .foregroundStyle(Theme.current.textSecondary.color)
                    .multilineTextAlignment(.center)
                HeaderPill("Edit rules", systemImage: "line.3.horizontal.decrease") { editingRules = true }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s7)
            .plainRow()
        }
        TaskRows(model: model, tasks: found, expanded: $expanded, scheduling: $scheduling)
    }

    // MARK: - Renaming

    private var renameTitle: String {
        switch renaming?.kind {
        case .newHeading: "New heading"
        case .heading: "Rename heading"
        default: "Rename"
        }
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func saveRename() {
        guard let rename = renaming else { return }
        renaming = nil
        let text = rename.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            switch rename.kind {
            case .list:
                guard !text.isEmpty else { return }
                await model.changeList(listID) { $0.name = text }
            case .newHeading:
                await model.addHeading(text, to: listID)
            case .heading(let id):
                guard !text.isEmpty else { return }
                await model.changeList(listID) { list in
                    if let index = list.headings.firstIndex(where: { $0.id == id }) { list.headings[index].title = text }
                }
            }
        }
    }
}

/// A small flat label, like an area's name or "Due Fri".
struct ListChip: View {
    enum Tone { case plain, accent, danger }
    let text: String
    var tone = Tone.plain

    var body: some View {
        let theme = Theme.current
        Text(text)
            .font(Typeface.micro)
            .foregroundStyle(tone == .danger ? theme.danger.color : tone == .accent ? theme.accent.color : theme.textSecondary.color)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1 - 1)
            .background(Capsule().fill(tone == .accent ? theme.highlight.color : theme.surface.color))
            .lineLimit(1)
    }
}

/// A project's heading, or "Loose tasks", with its count and, for a heading, a menu.
struct HeadingRow: View {
    let title: String
    var detail: String?
    var onAdd: (() -> Void)?
    var onRename: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s2) {
            Text(title)
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            if let onAdd, let onRename, let onRemove {
                Menu {
                    Button("Add a task here", systemImage: "plus", action: onAdd)
                    Button("Rename heading", systemImage: "pencil", action: onRename)
                    Button("Remove heading", systemImage: "minus.circle", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: Space.s6, height: Space.s6)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(title) options")
            }
        }
        .padding(.horizontal, Space.s1)
        .padding(.top, Space.s4)
    }
}

/// A project on its area's screen: ring, name, deadline and the next step.
struct ProjectCard: View {
    let model: TasksModel
    let project: TaskList
    let onOpen: () -> Void

    var body: some View {
        let theme = Theme.current
        let progress = model.projectProgress(of: project)
        Button(action: onOpen) {
            HStack(spacing: Space.s4) {
                TotalityUI.ProgressRing(progress: progress.fraction, diameter: Space.s7 + Space.s2) {
                    Text("\(progress.done)/\(progress.total)")
                        .font(Typeface.callout)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, Space.s1)
                }
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(project.displayName)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                    if let deadline = project.deadline {
                        let near = model.today.days(to: deadline, in: model.calendar) <= TaskRules.deadlineNear
                        Text("Due " + TaskText.day(deadline, today: model.today, in: model.calendar))
                            .font(Typeface.caption)
                            .foregroundStyle(near ? theme.danger.color : theme.textSecondary.color)
                    }
                    if let next = model.nextTask(in: project) {
                        Text("Next: \(next.displayTitle)")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("\(project.displayName), \(progress.done) of \(progress.total) done")
    }
}

/// A new project with nothing in it yet: first steps, and a few Inbox tasks it might take.
struct EmptyProject: View {
    let model: TasksModel
    let project: TaskList
    let onAdd: () -> Void
    let onHeading: () -> Void

    var body: some View {
        let theme = Theme.current
        let inbox = Array(model.tasks(in: .inbox).prefix(3))
        VStack(spacing: Space.s4) {
            VStack(spacing: Space.s2) {
                Image(systemName: "circle.dashed")
                    .font(Typeface.display)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s8, height: Space.s8)
                    .neumorphic(.subtle, in: Circle())
                    .padding(.bottom, Space.s2)
                    .accessibilityHidden(true)
                Text("No tasks yet")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text("Add the first step, or drag tasks in from Inbox or Anytime.")
                    .font(Typeface.callout.weight(.regular))
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: Space.s2) {
                HeaderPill("Add a task", systemImage: "plus", isProminent: true, action: onAdd)
                HeaderPill("Add a heading", systemImage: "text.badge.plus", action: onHeading)
            }
            if !inbox.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("From Inbox, maybe")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.bottom, Space.s1)
                    ForEach(inbox) { task in
                        Button {
                            Task { await model.move([task.id], to: .list(project.id)) }
                        } label: {
                            HStack(spacing: Space.s3) {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(theme.accent.color)
                                Text(task.displayTitle)
                                    .font(Typeface.body)
                                    .foregroundStyle(theme.textPrimary.color)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, Space.s2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SoftPress())
                        .accessibilityLabel("Move \(task.displayTitle) into \(project.displayName)")
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            }
        }
        .padding(.vertical, Space.s5)
    }
}

/// An area with nothing in it yet.
struct EmptyArea: View {
    let onProject: () -> Void
    let onTask: () -> Void

    var body: some View {
        VStack(spacing: Space.s3) {
            Text("Nothing here yet. Start a project, or add a task that belongs to this area.")
                .font(Typeface.callout.weight(.regular))
                .foregroundStyle(Theme.current.textSecondary.color)
                .multilineTextAlignment(.center)
            HStack(spacing: Space.s2) {
                HeaderPill("New project", systemImage: "circle", isProminent: true, action: onProject)
                HeaderPill("Add a task", systemImage: "plus", action: onTask)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s6)
    }
}
