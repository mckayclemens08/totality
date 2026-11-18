import SwiftUI
import TotalityUI

/// Type a task the way you'd say it. Each piece that's understood is highlighted as you type, and what
/// it means shows underneath. All of it is read on this device.
public struct QuickAddView: View {
    let model: TasksModel
    let bucket: TaskBucket
    /// A project or area to add into, and a heading in it.
    var list: UUID?
    var heading: UUID?
    let onDone: () -> Void
    @State private var text = ""
    @State private var added = 0
    @FocusState private var isFocused: Bool

    public init(model: TasksModel, bucket: TaskBucket, list: UUID? = nil, heading: UUID? = nil, onDone: @escaping () -> Void) {
        self.model = model
        self.bucket = bucket
        self.list = list
        self.heading = heading
        self.onDone = onDone
    }

    private var parsed: [ParsedTask] {
        QuickAddParser.parseLines(text, now: model.now, calendar: model.calendar)
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    TextField("Email Dr. Lee about chapter 2 tomorrow 9am #thesis", text: $text, axis: .vertical)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .focused($isFocused)
                        .lineLimit(1...8)
                        .raisedField()
                        .onChange(of: text) { old, new in
                            // Return at the end adds the task and starts the next. A pasted list stays to be checked.
                            if new.hasSuffix("\n"), new.count == old.count + 1 {
                                text = String(new.dropLast())
                                Task { await add(keepOpen: true) }
                            }
                        }
                    QuickAddPreview(parsed: parsed, text: text, model: model)
                    if added > 0 {
                        Text(added == 1 ? "1 task added" : "\(added) tasks added")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("New task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(added > 0 ? "Done" : "Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(parsed.count > 1 ? "Add \(parsed.count)" : "Add") { Task { await add(keepOpen: false) } }
                        .disabled(parsed.isEmpty)
                }
            }
        }
        .tint(theme.accent.color)
        .onAppear { isFocused = true }
    }

    private func add(keepOpen: Bool) async {
        guard !parsed.isEmpty else { return }
        let made = await model.add(text, in: bucket, list: list, heading: heading)
        added += made.count
        text = ""
        if !keepOpen, !made.isEmpty { onDone() }
    }
}

/// What was typed, with each understood piece highlighted, and below it what each piece means.
struct QuickAddPreview: View {
    let parsed: [ParsedTask]
    let text: String
    let model: TasksModel

    var body: some View {
        let theme = Theme.current
        if parsed.count == 1, let task = parsed.first, !task.pieces.isEmpty {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(Self.highlighted(text, task.pieces))
                    .font(Typeface.callout.weight(.regular))
                    .foregroundStyle(theme.textPrimary.color)
                    .accessibilityHidden(true)
                FlowRow {
                    ForEach(Array(meanings(of: task).enumerated()), id: \.offset) { _, meaning in
                        Label(meaning.text, systemImage: meaning.systemImage)
                            .font(Typeface.caption)
                            .foregroundStyle(meaning.isWarning ? theme.danger.color : theme.textSecondary.color)
                            .padding(.horizontal, Space.s3)
                            .padding(.vertical, Space.s1)
                            .neumorphic(.subtle, in: Capsule())
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Understood: " + meanings(of: task).map(\.text).joined(separator: ", "))
            }
        } else if parsed.count > 1 {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("\(parsed.count) tasks, one per line")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                ForEach(Array(parsed.prefix(12).enumerated()), id: \.offset) { _, task in
                    HStack(spacing: Space.s2) {
                        TickMark(isDone: false, diameter: Space.s4)
                        Text(task.title.isEmpty ? "New task" : task.title)
                            .font(Typeface.callout.weight(.regular))
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                        if let first = meanings(of: task).first {
                            Text(first.text).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        }
                    }
                }
            }
        }
    }

    struct Meaning {
        let text: String
        let systemImage: String
        var isWarning = false
    }

    private func meanings(of task: ParsedTask) -> [Meaning] {
        let today = model.today
        let calendar = model.calendar
        var found: [Meaning] = []
        if let when = task.when {
            found.append(.init(text: TaskText.day(when, today: today, in: calendar) + (task.isEvening ? " evening" : ""), systemImage: "calendar"))
        }
        if let time = task.time { found.append(.init(text: TaskText.time(time, in: calendar), systemImage: "clock")) }
        if let deadline = task.deadline {
            found.append(.init(text: TaskText.deadline(deadline, today: today, in: calendar), systemImage: "flag", isWarning: today.days(to: deadline, in: calendar) <= TaskRules.deadlineNear))
        }
        if let place = task.place { found.append(.init(text: place == .someday ? "Someday" : "Anytime", systemImage: place == .someday ? "archivebox" : "square.stack")) }
        if task.priority != .none { found.append(.init(text: task.priority.name + " priority", systemImage: "exclamationmark")) }
        found += task.tags.map { .init(text: "#" + $0, systemImage: "number") }
        return found
    }

    static func highlighted(_ text: String, _ pieces: [ParsedTask.Piece]) -> AttributedString {
        let theme = Theme.current
        var result = AttributedString()
        var index = text.startIndex
        for piece in pieces where piece.range.lowerBound >= index && piece.range.upperBound <= text.endIndex {
            result += AttributedString(String(text[index..<piece.range.lowerBound]))
            var marked = AttributedString(String(text[piece.range]))
            marked.backgroundColor = (piece.part == .deadline ? theme.highlightStrong : theme.highlight).color
            marked.foregroundColor = theme.textPrimary.color
            result += marked
            index = piece.range.upperBound
        }
        result += AttributedString(String(text[index...]))
        return result
    }
}
