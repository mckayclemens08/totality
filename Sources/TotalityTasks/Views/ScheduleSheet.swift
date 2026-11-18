import SwiftUI
import TotalityUI

/// Picks a task's When or Deadline: the usual choices first, then any day.
struct ScheduleSheet: View {
    let model: TasksModel
    let target: ScheduleTarget
    let onDone: () -> Void
    @State private var day = Date()
    /// The deadline's optional time, which "1 hour before" counts back from.
    @State private var deadlineTime: Date?

    var body: some View {
        let theme = Theme.current
        let today = model.today
        let calendar = model.calendar
        let task = model.tasks.first { $0.id == target.id }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if target.kind == .when {
                        VStack(spacing: 0) {
                            option("Today", systemImage: "star") { .day(today, evening: false) }
                            option("This evening", systemImage: "moon") { .day(today, evening: true) }
                            option("Tomorrow", systemImage: "sunrise") { .day(today.adding(days: 1, in: calendar), evening: false) }
                            option("Anytime", systemImage: "square.stack") { .anytime }
                            option("Someday", systemImage: "archivebox") { .someday }
                        }
                        .padding(Space.s2)
                        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    DatePicker(target.kind == .when ? "Day" : "Deadline", selection: $day, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.calendar, calendar)
                        .environment(\.timeZone, calendar.timeZone)
                        .padding(Space.s3)
                        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    if target.kind == .deadline {
                        HStack {
                            Toggle("At a time", isOn: Binding(
                                get: { deadlineTime != nil },
                                set: { deadlineTime = $0 ? TaskDay(year: 2026, month: 1, day: 15).date(at: TaskTime(hour: 17)!, in: calendar) : nil }
                            ))
                            .font(Typeface.body)
                            .tint(theme.accent.color)
                            if let chosen = deadlineTime {
                                DatePicker("Time", selection: Binding(get: { chosen }, set: { deadlineTime = $0 }), displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .environment(\.calendar, calendar)
                                    .environment(\.timeZone, calendar.timeZone)
                            }
                        }
                        .raisedField()
                    }
                    if target.kind == .deadline, task?.deadline != nil {
                        Button("Remove deadline", role: .destructive) {
                            Task {
                                for id in target.ids {
                                    await model.change(id) {
                                        $0.deadline = nil
                                        $0.deadlineTime = nil
                                    }
                                }
                                onDone()
                            }
                        }
                        .font(Typeface.callout)
                        .foregroundStyle(theme.danger.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(target.kind == .when ? "When" : "Deadline")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let chosen = TaskDay(day, in: calendar)
                        Task {
                            if target.kind == .when {
                                await model.schedule(target.ids, .day(chosen, evening: false))
                            } else {
                                let time = deadlineTime.map { TaskTime($0, in: calendar) }
                                for id in target.ids {
                                    await model.change(id) {
                                        $0.deadline = chosen
                                        $0.deadlineTime = time
                                    }
                                }
                            }
                            onDone()
                        }
                    }
                }
            }
        }
        .tint(theme.accent.color)
        .onAppear {
            let current = target.kind == .when ? task?.when : task?.deadline
            day = (current ?? today).start(in: calendar).addingTimeInterval(12 * 3600)
            if target.kind == .deadline, let time = task?.deadlineTime {
                deadlineTime = TaskDay(year: 2026, month: 1, day: 15).date(at: time, in: calendar)
            }
        }
    }

    private func option(_ name: String, systemImage: String, _ choice: @escaping () -> ScheduleChoice) -> some View {
        let theme = Theme.current
        return Button {
            Task {
                await model.schedule(target.ids, choice())
                onDone()
            }
        } label: {
            Label(name, systemImage: systemImage)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
