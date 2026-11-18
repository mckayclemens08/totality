import SwiftUI
import TotalityUI

/// A small round choice: the chosen one is filled with the accent, the rest stand a little off the page.
/// Never pressed in.
struct OptionPill: View {
    let title: String
    let isOn: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Text(title)
                .font(Typeface.callout)
                .lineLimit(1)
                .foregroundStyle(isOn ? theme.accentOn.color : (isEnabled ? theme.textSecondary.color : theme.textTertiary.color))
                .padding(.horizontal, Space.s3 + Space.s1 / 2)
                .padding(.vertical, Space.s2)
                .fixedSize()
                .background {
                    if isOn {
                        Capsule().fill(theme.accent.color)
                    } else {
                        Color.clear.neumorphic(.subtle, in: Capsule())
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A grey heading over a group, like "Ends".
struct GroupLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typeface.caption.weight(.semibold))
            .foregroundStyle(Theme.current.textSecondary.color)
            .padding(.horizontal, Space.s1)
            .padding(.top, Space.s2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Picks how a task repeats: daily, weekly on days, monthly, yearly, after it's finished, or custom, and
/// when it ends. Matches the "repeat picker" board.
struct RepeatSheet: View {
    let model: TasksModel
    let taskID: UUID
    let onDone: () -> Void
    @State private var rule: RepeatRule
    @State private var endKind = EndKind.never
    @State private var endDate = Date()
    @State private var endTimes = 10

    enum EndKind { case never, date, times }

    init(model: TasksModel, taskID: UUID, onDone: @escaping () -> Void) {
        self.model = model
        self.taskID = taskID
        self.onDone = onDone
        let task = model.tasks.first { $0.id == taskID }
        let start = task.flatMap(TaskRepeats.anchor(of:)) ?? model.today
        let existing = task?.repeatRule
        _rule = State(initialValue: existing ?? RepeatRule(kind: .weekly, start: start))
        switch existing?.end {
        case .on(let day):
            _endKind = State(initialValue: .date)
            _endDate = State(initialValue: day.start(in: model.calendar).addingTimeInterval(12 * 3600))
        case .after(let times):
            _endKind = State(initialValue: .times)
            _endTimes = State(initialValue: times)
        default:
            _endDate = State(initialValue: start.adding(days: 30, in: model.calendar).start(in: model.calendar).addingTimeInterval(12 * 3600))
        }
    }

    private var calendar: Calendar { model.calendar }

    private var finished: RepeatRule {
        var result = rule
        switch endKind {
        case .never: result.end = .never
        case .date: result.end = .on(TaskDay(endDate, in: calendar))
        case .times: result.end = .after(times: endTimes)
        }
        return result
    }

    var body: some View {
        let theme = Theme.current
        let task = model.tasks.first { $0.id == taskID }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if let task {
                        Text(task.displayTitle)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(RepeatRule.Kind.allCases, id: \.self) { kind in
                        kindRow(kind)
                    }
                    GroupLabel("Ends")
                    HStack(spacing: Space.s2) {
                        OptionPill(title: "Never", isOn: endKind == .never) { endKind = .never }
                        OptionPill(title: "On a date", isOn: endKind == .date) { endKind = .date }
                        OptionPill(title: "After \(endTimes) times", isOn: endKind == .times) { endKind = .times }
                    }
                    if endKind == .date {
                        DatePicker("Last day", selection: $endDate, displayedComponents: .date)
                            .font(Typeface.body)
                            .environment(\.calendar, calendar)
                            .environment(\.timeZone, calendar.timeZone)
                            .raisedField()
                    } else if endKind == .times {
                        Stepper("\(endTimes) times", value: $endTimes, in: 1...365)
                            .font(Typeface.body)
                            .raisedField()
                    }
                    summary
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Repeat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let chosen = finished
                        Task {
                            await model.setRepeat(taskID, chosen)
                            onDone()
                        }
                    }
                }
            }
        }
        .tint(theme.accent.color)
    }

    private static func subtitle(_ kind: RepeatRule.Kind) -> String {
        switch kind {
        case .daily: "Every day, or every few days"
        case .weekly: "On the days you pick"
        case .monthly: "A date, or a weekday like the last Friday"
        case .yearly: "Once a year, on the same date"
        case .afterFinish: "A while after you tick it off, or after the due date"
        case .custom: "Every 2 weeks on Tuesday, every weekday…"
        }
    }

    private static func name(_ kind: RepeatRule.Kind) -> String {
        switch kind {
        case .daily: "Daily"
        case .weekly: "Weekly on days"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        case .afterFinish: "After I finish"
        case .custom: "Custom"
        }
    }

    private func kindRow(_ kind: RepeatRule.Kind) -> some View {
        let theme = Theme.current
        let isOn = rule.kind == kind
        return VStack(alignment: .leading, spacing: Space.s3) {
            Button {
                choose(kind)
            } label: {
                HStack(spacing: Space.s3) {
                    ChoiceMark(isOn: isOn)
                    VStack(alignment: .leading, spacing: Space.s1 / 2) {
                        Text(Self.name(kind))
                            .font(isOn ? Typeface.body.weight(.semibold) : Typeface.body)
                            .foregroundStyle(theme.textPrimary.color)
                        Text(isOn ? rule.summary(in: calendar) : Self.subtitle(kind))
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            if isOn { options(for: kind).padding(.leading, Metric.choiceMark + Space.s3) }
        }
        .padding(.horizontal, Space.s3 + Space.s1 / 2)
        .padding(.vertical, Space.s3)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private func choose(_ kind: RepeatRule.Kind) {
        rule.kind = kind
        rule.interval = 1
        rule.monthWeekday = nil
        rule.monthDays = []
        rule.weekdays = kind == .weekly || kind == .custom ? [rule.start.weekday(in: calendar)] : []
        rule.customUnit = kind == .custom ? .week : .day
    }

    @ViewBuilder
    private func options(for kind: RepeatRule.Kind) -> some View {
        switch kind {
        case .daily:
            every(unitName: "day")
        case .weekly:
            VStack(alignment: .leading, spacing: Space.s3) {
                every(unitName: "week", suffix: "on")
                WeekdayPicker(days: $rule.weekdays, calendar: calendar)
            }
        case .monthly:
            VStack(alignment: .leading, spacing: Space.s3) {
                every(unitName: "month")
                monthOptions
            }
        case .yearly:
            VStack(alignment: .leading, spacing: Space.s2) {
                every(unitName: "year")
                Text("On \(rule.start.day) \(calendar.monthSymbols[rule.start.month - 1]), the task's day")
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.textSecondary.color)
            }
        case .afterFinish:
            VStack(alignment: .leading, spacing: Space.s3) {
                unitPicker(units: [.day, .week, .month], label: "after")
                HStack(spacing: Space.s2) {
                    OptionPill(title: "I tick it off", isOn: rule.countFrom == .completion) { rule.countFrom = .completion }
                    OptionPill(title: "The due date", isOn: rule.countFrom == .dueDate) { rule.countFrom = .dueDate }
                }
            }
        case .custom:
            VStack(alignment: .leading, spacing: Space.s3) {
                unitPicker(units: RepeatRule.Unit.allCases, label: "Every", leading: true)
                if rule.customUnit == .week {
                    WeekdayPicker(days: $rule.weekdays, calendar: calendar)
                    OptionPill(title: "Every weekday", isOn: rule.weekdays == [2, 3, 4, 5, 6]) { rule.weekdays = [2, 3, 4, 5, 6] }
                }
            }
        }
    }

    private func every(unitName: String, suffix: String = "") -> some View {
        HStack(spacing: Space.s2) {
            Text("Every")
            Menu {
                Picker("Every", selection: $rule.interval) {
                    ForEach(1...30, id: \.self) { n in Text("\(n) \(unitName)\(n == 1 ? "" : "s")").tag(n) }
                }
            } label: {
                pillLabel("\(rule.interval) \(unitName)\(rule.interval == 1 ? "" : "s")")
            }
            .buttonStyle(.plain)
            if !suffix.isEmpty { Text(suffix) }
        }
        .font(Typeface.callout)
        .foregroundStyle(Theme.current.textSecondary.color)
    }

    private func unitPicker(units: [RepeatRule.Unit], label: String, leading: Bool = false) -> some View {
        HStack(spacing: Space.s2) {
            if leading { Text(label) }
            Menu {
                Picker("How many", selection: $rule.interval) {
                    ForEach(1...30, id: \.self) { Text("\($0)").tag($0) }
                }
            } label: {
                pillLabel("\(rule.interval)")
            }
            .buttonStyle(.plain)
            Menu {
                Picker("Unit", selection: $rule.customUnit) {
                    ForEach(units, id: \.self) { Text($0.rawValue + "s").tag($0) }
                }
            } label: {
                pillLabel(rule.customUnit.rawValue + (rule.interval == 1 ? "" : "s"))
            }
            .buttonStyle(.plain)
            if !leading { Text(label) }
        }
        .font(Typeface.callout)
        .foregroundStyle(Theme.current.textSecondary.color)
    }

    private func pillLabel(_ text: String) -> some View {
        let theme = Theme.current
        return Text(text)
            .font(Typeface.callout.weight(.semibold))
            .foregroundStyle(theme.accentOn.color)
            .padding(.horizontal, Space.s3 + Space.s1 / 2)
            .padding(.vertical, Space.s2)
            .background(Capsule().fill(theme.accent.color))
            .fixedSize()
    }

    private var monthOptions: some View {
        let byWeekday = rule.monthWeekday != nil
        let ordinals: [(Int, String)] = [(1, "First"), (2, "Second"), (3, "Third"), (4, "Fourth"), (-1, "Last")]
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                OptionPill(title: "On a date", isOn: !byWeekday) { rule.monthWeekday = nil }
                OptionPill(title: "On a weekday", isOn: byWeekday) {
                    rule.monthWeekday = .init(ordinal: -1, weekday: rule.start.weekday(in: calendar))
                    rule.monthDays = []
                }
            }
            if let weekday = rule.monthWeekday {
                HStack(spacing: Space.s2) {
                    Text("The")
                    Menu {
                        Picker("Which", selection: Binding(get: { weekday.ordinal }, set: { rule.monthWeekday?.ordinal = $0 })) {
                            ForEach(ordinals, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    } label: { pillLabel(ordinals.first { $0.0 == weekday.ordinal }?.1 ?? "Last") }
                    .buttonStyle(.plain)
                    Menu {
                        Picker("Weekday", selection: Binding(get: { weekday.weekday }, set: { rule.monthWeekday?.weekday = $0 })) {
                            ForEach(1...7, id: \.self) { Text(calendar.weekdaySymbols[$0 - 1]).tag($0) }
                        }
                    } label: { pillLabel(calendar.weekdaySymbols[weekday.weekday - 1]) }
                    .buttonStyle(.plain)
                }
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textSecondary.color)
            } else {
                MonthDayPicker(days: $rule.monthDays, start: rule.start.day)
            }
        }
    }

    private var summary: some View {
        let theme = Theme.current
        let chosen = finished
        let anchor = model.tasks.first { $0.id == taskID }.flatMap(TaskRepeats.anchor(of:)) ?? chosen.start
        var words = chosen.summary(in: calendar)
        if case .on(let last) = chosen.end { words += " until " + TaskText.day(last, today: model.today, in: calendar) }
        if let next = chosen.next(after: anchor, in: calendar) {
            words += ". Next: " + TaskText.heading(next, today: model.today, in: calendar)
        }
        return HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "repeat")
                .foregroundStyle(theme.accent.color)
                .accessibilityHidden(true)
            Text(words)
                .foregroundStyle(theme.textSecondary.color)
        }
        .font(Typeface.caption)
        .padding(.horizontal, Space.s1)
        .padding(.top, Space.s3)
    }
}

/// The round mark of a one-of-several choice.
struct ChoiceMark: View {
    let isOn: Bool

    var body: some View {
        let theme = Theme.current
        ZStack {
            if isOn {
                Circle().fill(theme.accent.color)
                Image(systemName: "checkmark")
                    .font(Typeface.micro.weight(.bold))
                    .foregroundStyle(theme.accentOn.color)
            } else {
                Circle().strokeBorder(theme.shadowDark.color, lineWidth: Space.s1 / 2)
            }
        }
        .frame(width: Metric.choiceMark, height: Metric.choiceMark)
        .accessibilityHidden(true)
    }
}

/// Seven round day buttons, in the person's week order.
struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    let calendar: Calendar

    var body: some View {
        let theme = Theme.current
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: Space.s1) {
            ForEach(order, id: \.self) { day in
                let isOn = days.contains(day)
                Button {
                    if isOn, days.count > 1 { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[day - 1])
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(isOn ? theme.accentOn.color : theme.textSecondary.color)
                        .frame(width: Space.s6 + Space.s1, height: Space.s6 + Space.s1)
                        .background {
                            if isOn { Circle().fill(theme.accent.color) } else { Color.clear.neumorphic(.subtle, in: Circle()) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// Days of the month, with the last day as its own choice.
struct MonthDayPicker: View {
    @Binding var days: Set<Int>
    let start: Int

    var body: some View {
        let shown = days.isEmpty ? [start] : days
        FlowRow {
            ForEach(Array(1...31) + [-1], id: \.self) { day in
                OptionPill(title: day < 0 ? "Last day" : "\(day)", isOn: shown.contains(day)) {
                    var next = shown
                    if next.contains(day), next.count > 1 { next.remove(day) } else { next.insert(day) }
                    days = next
                }
            }
        }
    }
}

/// The repeat on an open task: how it repeats, the next few dates with skipped ones crossed out, and
/// Skip next, Edit repeat and Stop repeating. Matches the "repeating task" board.
struct RepeatCard: View {
    let model: TasksModel
    let task: TaskItem
    let onEdit: () -> Void

    var body: some View {
        let theme = Theme.current
        let calendar = model.calendar
        let today = model.today
        if let rule = task.repeatRule {
            let anchor = TaskRepeats.anchor(of: task) ?? today
            let next = rule.next(after: anchor, in: calendar)
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack(spacing: Space.s3) {
                    Image(systemName: "repeat")
                        .font(Typeface.body)
                        .foregroundStyle(theme.accent.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.s1 / 2) {
                        Text(rule.summary(in: calendar))
                            .font(Typeface.body.weight(.semibold))
                            .foregroundStyle(theme.textPrimary.color)
                        if let ends = endLine(rule, anchor: anchor) {
                            Text(ends)
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    Spacer(minLength: Space.s1)
                    if let next {
                        Text("Next " + TaskText.day(next, today: today, in: calendar))
                            .font(Typeface.micro.weight(.semibold))
                            .foregroundStyle(theme.accent.color)
                            .padding(.horizontal, Space.s2)
                            .padding(.vertical, Space.s1)
                            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(theme.highlight.color))
                    }
                }
                .padding(Space.s3)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                GroupLabel("Coming up")
                VStack(spacing: 0) {
                    let coming = rule.upcoming(from: anchor, count: 4, in: calendar)
                    ForEach(0..<coming.count, id: \.self) { index in
                        comingRow(index: index, day: coming[index].day, skipped: coming[index].skipped)
                        if index < coming.count - 1 {
                            Rectangle().fill(theme.shadowDark.color).frame(height: Space.hairline)
                        }
                    }
                }
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s1)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                FlowRow {
                    OptionPill(title: "Skip next", isOn: false) { Task { await model.skipNext(task.id) } }
                    OptionPill(title: "Edit repeat", isOn: false, action: onEdit)
                    OptionPill(title: "Stop repeating", isOn: false) { Task { await model.setRepeat(task.id, nil) } }
                }
                if let next {
                    Text("Tick it off and the next one appears on \(TaskText.heading(next, today: today, in: calendar)). Tap a coming date to skip it.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
        }
    }

    private func comingRow(index: Int, day: TaskDay, skipped: Bool) -> some View {
        let theme = Theme.current
        let note = skipped ? "skipped" : (index == 0 ? "this one" : (index == 1 ? "next" : ""))
        return Button {
            guard index > 0 else { return }
            Task { await model.toggleSkip(task.id, on: day) }
        } label: {
            HStack {
                Text(TaskText.heading(day, today: model.today, in: model.calendar))
                    .strikethrough(skipped)
                    .foregroundStyle(skipped ? theme.textSecondary.color : theme.textPrimary.color)
                Spacer()
                Text(note)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .font(Typeface.callout.weight(.regular))
            .padding(.vertical, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(index == 0 ? "" : (skipped ? "Brings this date back" : "Skips this date"))
    }

    private func endLine(_ rule: RepeatRule, anchor: TaskDay) -> String? {
        let calendar = model.calendar
        let left = rule.remaining(after: anchor, in: calendar).map { "\($0) left" }
        switch rule.end {
        case .never: return nil
        case .on(let last): return ["Until " + TaskText.day(last, today: model.today, in: calendar), left].compactMap { $0 }.joined(separator: " · ")
        case .after(let times): return ["\(times) times in all", left].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
