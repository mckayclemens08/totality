import SwiftUI
import TotalityCore
import TotalityUI

/// A small sheet with a title, Cancel and a confirm button, on the theme's surface.
private struct SheetFrame<Content: View>: View {
    let title: String
    let confirm: String
    let canConfirm: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) { content }
                    .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm, action: onConfirm).disabled(!canConfirm)
                }
            }
        }
        .tint(theme.accent.color)
    }
}

/// A label above a field, quiet.
private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typeface.caption.weight(.semibold))
            .foregroundStyle(Theme.current.textSecondary.color)
            .padding(.horizontal, Space.s1)
    }
}

/// Makes an area or a project. A project can sit in an area and have a deadline.
struct NewListSheet: View {
    let model: TasksModel
    let kind: TaskList.Kind
    var area: UUID?
    /// The new list's ID, or nil when cancelled.
    let onDone: (UUID?) -> Void
    @State private var name = ""
    @State private var chosenArea: UUID?
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @FocusState private var focused: Bool

    var body: some View {
        let theme = Theme.current
        SheetFrame(
            title: kind == .area ? "New area" : "New project", confirm: "Make", canConfirm: !trimmed.isEmpty,
            onCancel: { onDone(nil) }, onConfirm: make
        ) {
            FieldLabel("Name")
            TextField(kind == .area ? "School" : "Hegel paper", text: $name)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(make)
                .raisedField()
            if kind == .project {
                if !model.areas.isEmpty {
                    HStack {
                        Text("Area").font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                        Spacer()
                        Picker("Area", selection: $chosenArea) {
                            Text("No area").tag(UUID?.none)
                            ForEach(model.areas) { Text($0.displayName).tag(Optional($0.id)) }
                        }
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s2)
                    .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                VStack(alignment: .leading, spacing: Space.s2) {
                    Toggle("Deadline", isOn: $hasDeadline)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                    if hasDeadline {
                        DatePicker("Deadline", selection: $deadline, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .environment(\.calendar, model.calendar)
                            .environment(\.timeZone, model.calendar.timeZone)
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .motion(Motion.snappy, value: hasDeadline)
            }
        }
        .onAppear {
            chosenArea = area
            focused = true
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func make() {
        guard !trimmed.isEmpty else { return }
        let day = hasDeadline ? TaskDay(deadline, in: model.calendar) : nil
        Task {
            let made = await model.addList(name: trimmed, kind: kind, area: chosenArea, deadline: day)
            onDone(made?.id)
        }
    }
}

/// Sets or clears a project's deadline.
struct DeadlineSheet: View {
    let model: TasksModel
    let project: TaskList
    let onDone: () -> Void
    @State private var day = Date()

    var body: some View {
        let theme = Theme.current
        SheetFrame(title: "Deadline", confirm: "Done", canConfirm: true, onCancel: onDone) {
            let chosen = TaskDay(day, in: model.calendar)
            Task {
                await model.changeList(project.id) { $0.deadline = chosen }
                onDone()
            }
        } content: {
            DatePicker("Deadline", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .environment(\.calendar, model.calendar)
                .environment(\.timeZone, model.calendar.timeZone)
                .padding(Space.s3)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            if project.deadline != nil {
                Button("Remove deadline", role: .destructive) {
                    Task {
                        await model.changeList(project.id) { $0.deadline = nil }
                        onDone()
                    }
                }
                .font(Typeface.callout)
                .foregroundStyle(theme.danger.color)
            }
        }
        .onAppear {
            day = (project.deadline ?? model.today).start(in: model.calendar).addingTimeInterval(12 * 3600)
        }
    }
}

/// Builds a smart list: a name, one all/any switch, flat rules (no nested groups, owner 2026-11-18), a
/// live preview of what it finds, and whether it's pinned to Lists.
struct SmartListEditor: View {
    let model: TasksModel
    /// The list being edited, or nil for a new one.
    var existing: TaskList?
    let onDone: () -> Void
    @State private var name = ""
    @State private var rules = SmartRules()
    @State private var isPinned = true
    @State private var typingTagFor: UUID?
    @State private var typedTag = ""

    private static let dayChoices: [Int?] = [0, 1, 3, 7, 14, 30, nil]

    var body: some View {
        let theme = Theme.current
        let found = model.tasks(matching: rules)
        SheetFrame(
            title: "Smart list", confirm: "Save", canConfirm: !trimmed.isEmpty, onCancel: onDone, onConfirm: save
        ) {
            FieldLabel("Name")
            TextField("Due this week, School", text: $name)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .raisedField()
            HStack(spacing: Space.s2) {
                Text("Show tasks that match")
                ForEach(SmartRules.Match.allCases, id: \.self) { match in
                    FilterPill(match.rawValue, isSelected: rules.match == match) {
                        withMotion(Motion.snappy) { rules.match = match }
                    }
                    .accessibilityLabel("Match \(match.rawValue) rules")
                }
                Text("of these rules")
            }
            .font(Typeface.callout.weight(.regular))
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            VStack(spacing: Space.s3) {
                ForEach($rules.rules) { $rule in
                    ruleRow($rule)
                }
                Menu {
                    ForEach(SmartRule.Kind.pickable, id: \.self) { kind in
                        Button(kind.name) { withMotion(Motion.snappy) { rules.rules.append(starter(kind)) } }
                    }
                } label: {
                    Label("Add a rule", systemImage: "plus")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.s2)
                        .padding(.horizontal, Space.s1)
                }
            }
            Text("Rules can use tag, area, project, priority, when, deadline and whether a task has a note.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, Space.s1)
            preview(found)
            Toggle("Pin to Lists", isOn: $isPinned)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .alert("Tag", isPresented: Binding(get: { typingTagFor != nil }, set: { if !$0 { typingTagFor = nil } })) {
            TextField("thesis", text: $typedTag)
            Button("Cancel", role: .cancel) { typingTagFor = nil }
            Button("Use") {
                if let id = typingTagFor, let index = rules.rules.firstIndex(where: { $0.id == id }) {
                    rules.rules[index].tag = typedTag.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
                }
                typingTagFor = nil
            }
        }
        .onAppear {
            guard let existing else { return }
            name = existing.name
            rules = existing.rules ?? SmartRules()
            isPinned = existing.isPinned
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        Task {
            if let existing {
                await model.changeList(existing.id) { list in
                    list.name = trimmed
                    list.rules = rules
                    list.isPinned = isPinned
                }
            } else {
                await model.addList(name: trimmed, kind: .smart, rules: rules, isPinned: isPinned)
            }
            onDone()
        }
    }

    /// A new rule with a sensible first value, so it does something at once.
    private func starter(_ kind: SmartRule.Kind) -> SmartRule {
        switch kind {
        case .tag: SmartRule(kind: .tag, tag: model.allTags.first)
        case .area: SmartRule(kind: .area, listID: model.areas.first?.id)
        case .project: SmartRule(kind: .project, listID: model.lists.first { $0.kind == .project }?.id)
        case .priority: SmartRule(kind: .priority, priority: .high)
        case .when: SmartRule(kind: .when, days: 0)
        case .deadline: SmartRule(kind: .deadline, days: 7)
        case .hasNote, .unknown: SmartRule(kind: kind)
        }
    }

    private func ruleRow(_ rule: Binding<SmartRule>) -> some View {
        let theme = Theme.current
        let value = rule.wrappedValue
        return HStack(spacing: Space.s2) {
            Text(value.kind.name)
                .font(Typeface.callout)
                .foregroundStyle(theme.textPrimary.color)
            Menu {
                switch value.kind {
                case .when, .deadline:
                    ForEach(Self.dayChoices, id: \.self) { days in
                        Button(daysName(days)) { rule.wrappedValue.days = days }
                    }
                default:
                    Button(value.kind == .hasNote ? "yes" : "is") { rule.wrappedValue.isNegated = false }
                    Button(value.kind == .hasNote ? "no" : "is not") { rule.wrappedValue.isNegated = true }
                }
            } label: {
                Text(operatorName(value))
                    .font(Typeface.callout.weight(.regular))
                    .foregroundStyle(theme.textSecondary.color)
            }
            valueMenu(rule)
            Spacer(minLength: 0)
            Button {
                withMotion(Motion.snappy) { rules.rules.removeAll { $0.id == value.id } }
            } label: {
                Image(systemName: "xmark")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s6, height: Space.s6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            .accessibilityLabel("Remove the \(value.kind.name) rule")
        }
        .lineLimit(1)
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    @ViewBuilder private func valueMenu(_ rule: Binding<SmartRule>) -> some View {
        let value = rule.wrappedValue
        switch value.kind {
        case .tag:
            Menu {
                ForEach(model.allTags, id: \.self) { tag in Button(tag) { rule.wrappedValue.tag = tag } }
                Button("Type a tag…") {
                    typedTag = value.tag ?? ""
                    typingTagFor = value.id
                }
            } label: { ListChip(text: value.tag.map { $0.isEmpty ? "Choose" : $0 } ?? "Choose", tone: .accent) }
        case .area, .project:
            let choices = value.kind == .area ? model.areas : model.lists.filter { $0.kind == .project }
            Menu {
                ForEach(choices) { list in Button(list.displayName) { rule.wrappedValue.listID = list.id } }
            } label: { ListChip(text: model.list(value.listID)?.displayName ?? "Choose", tone: .accent) }
        case .priority:
            Menu {
                ForEach(TaskItem.Priority.allCases, id: \.self) { priority in
                    Button(priority.name) { rule.wrappedValue.priority = priority }
                }
            } label: { ListChip(text: value.priority?.name ?? "Choose", tone: .accent) }
        case .when, .deadline, .hasNote, .unknown:
            EmptyView()
        }
    }

    private func operatorName(_ rule: SmartRule) -> String {
        switch rule.kind {
        case .when, .deadline: daysName(rule.days)
        case .hasNote: rule.isNegated ? "no" : "yes"
        default: rule.isNegated ? "is not" : "is"
        }
    }

    private func daysName(_ days: Int?) -> String {
        switch days {
        case nil: "is set"
        case 0: "is today or earlier"
        case 1: "is within 1 day"
        case let days?: "is within \(days) days"
        }
    }

    private func preview(_ found: [TaskItem]) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview").font(Typeface.callout)
                Spacer()
                Text(found.count == 1 ? "1 task" : "\(found.count) tasks").font(Typeface.caption)
            }
            .foregroundStyle(theme.textSecondary.color)
            .padding(.bottom, Space.s1)
            if found.isEmpty {
                Text(rules.rules.isEmpty ? "Add a rule to see what it finds." : "Nothing matches yet.")
                    .font(Typeface.callout.weight(.regular))
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.vertical, Space.s2)
            }
            ForEach(found.prefix(3)) { task in
                HStack(spacing: Space.s3) {
                    TickMark(isDone: false)
                    Text(task.displayTitle)
                        .font(Typeface.callout.weight(.regular))
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let deadline = task.deadline {
                        let near = TaskRules.deadlineIsNear(task, today: model.today, in: model.calendar)
                        Text(TaskText.day(deadline, today: model.today, in: model.calendar))
                            .font(Typeface.caption)
                            .foregroundStyle(near ? theme.danger.color : theme.textSecondary.color)
                    }
                }
                .padding(.vertical, Space.s2)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

/// Every place a task can go, for Move and the drag tray: the fixed lists, then projects and areas.
struct DestinationChoice: Identifiable, Hashable {
    let destination: TaskDestination
    let name: String
    let systemImage: String

    var id: TaskDestination { destination }

    @MainActor
    static func all(in model: TasksModel) -> [DestinationChoice] {
        var choices: [DestinationChoice] = [TaskBucket.inbox, .today, .anytime, .someday].map {
            DestinationChoice(destination: .bucket($0), name: $0.name, systemImage: $0.systemImage)
        }
        let projects = model.lists.filter { $0.kind == .project && $0.status == .active }
        choices += ListRules.ordered(projects).map {
            DestinationChoice(destination: .list($0.id), name: $0.displayName, systemImage: "circle")
        }
        choices += model.areas.map {
            DestinationChoice(destination: .list($0.id), name: $0.displayName, systemImage: "square.stack")
        }
        return choices
    }
}

/// Moves the picked tasks to a list.
struct MoveSheet: View {
    let model: TasksModel
    let ids: Set<UUID>
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(DestinationChoice.all(in: model)) { choice in
                        Button {
                            Task {
                                await model.move(ids, to: choice.destination)
                                onDone()
                            }
                        } label: {
                            Label(choice.name, systemImage: choice.systemImage)
                                .font(Typeface.body)
                                .foregroundStyle(theme.textPrimary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Space.s3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SoftPress())
                    }
                }
                .padding(Space.s2)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(ids.count == 1 ? "Move 1 task" : "Move \(ids.count) tasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
            }
        }
        .tint(theme.accent.color)
    }
}

/// Adds one tag to the picked tasks: one already in use, or a new one.
struct TagSheet: View {
    let model: TasksModel
    let ids: Set<UUID>
    let onDone: () -> Void
    @State private var tag = ""

    var body: some View {
        let theme = Theme.current
        SheetFrame(title: "Add a tag", confirm: "Add", canConfirm: !tag.trimmingCharacters(in: .whitespaces).isEmpty, onCancel: onDone) {
            apply(tag)
        } content: {
            TextField("errands", text: $tag)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { apply(tag) }
                .raisedField()
            if !model.allTags.isEmpty {
                FieldLabel("In use")
                FlowRow {
                    ForEach(model.allTags, id: \.self) { existing in
                        FilterPill(existing, isSelected: false) { apply(existing) }
                    }
                }
            }
        }
    }

    private func apply(_ text: String) {
        Task {
            await model.addTag(text, to: ids)
            onDone()
        }
    }
}
