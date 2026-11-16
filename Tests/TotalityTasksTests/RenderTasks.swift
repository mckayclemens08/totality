#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import TotalityCore
import TotalityUI
@testable import TotalityTasks

/// Writes Tasks' screens in each state to PNGs for a person to look at, when TOTALITY_RENDER_DIR is set.
/// ImageRenderer draws List and ScrollView blank, so each screen is drawn from what they hold.
@MainActor
@Suite struct RenderTasks {
    private func write(_ view: some View, name: String, to directory: String, width: CGFloat = 393, height: CGFloat = 852) throws {
        let renderer = ImageRenderer(content: view
            .frame(width: width, height: height, alignment: .top)
            .background(Theme.current.bg.color))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// The owner's own kinds of tasks, across every list.
    private func model() async throws -> TasksModel {
        let model = TasksModel(vault: TaskVault(store: MemoryBlobs(), rootKey: try .generate()), calendar: denver, now: { agreed })
        model.agenda = { from, to in
            [
                AgendaItem(id: "1", title: "Phonology lecture", start: moment(2026, 11, 16, 9), end: moment(2026, 11, 16, 10, 30), isAllDay: false),
                AgendaItem(id: "2", title: "Debate club", start: moment(2026, 11, 17, 16), end: moment(2026, 11, 17, 18), isAllDay: false),
                AgendaItem(id: "3", title: "MUN conference", start: day(2026, 11, 20).start(in: denver), end: day(2026, 11, 22).start(in: denver), isAllDay: true),
            ].filter { $0.touches(from: from, to: to) }
        }
        await model.load()
        for line in [
            "Email Dr. Lee about thesis chapter 2 9am #school !high",
            "Read Hayes, Introductory Phonology ch. 4 #school",
            "Finish MUN position paper on water rights due Wednesday #mun !medium",
            "Pick up blazer from the cleaners tonight",
        ] { await model.add(line, in: .today) }
        let pack = try #require(await model.add("Pack for the MUN conference Thursday #mun", in: .inbox).first)
        await model.change(pack.id) {
            $0.checklist = [.init(title: "Country placard", isDone: true), .init(title: "Blazer"), .init(title: "Laptop charger"),
                            .init(title: "Printed resolutions"), .init(title: "Badge")]
        }
        await model.add("Book a study room for the thesis group tomorrow 3pm", in: .inbox)
        await model.add("Thesis draft due Friday #school/thesis", in: .anytime)
        await model.add("Conlang: write the case-marking chapter #conlang", in: .anytime)
        await model.add("Sort the Zotero library", in: .anytime)
        await model.add("Try a Lisbon walking route", in: .someday)
        await model.add("Learn the Shavian alphabet", in: .someday)
        await model.add("Capture: MUN committee names idea", in: .inbox)
        await model.add("Reading response on Hayes ch. 3", in: .anytime)
        let overdue = try #require(model.tasks.first { $0.title == "Reading response on Hayes ch. 3" })
        await model.change(overdue.id) { $0.deadline = day(2026, 11, 13) }
        for title in ["Submit MUN registration", "Outline thesis chapter 1", "Email the debate coach"] {
            let task = try #require(await model.add(title, in: .anytime).first)
            await model.toggle(task.id)
        }
        let email = try #require(model.tasks.first { $0.title.hasPrefix("Email Dr. Lee") })
        await model.change(email.id) { $0.notes = "Ask about the **corpus** for chapter 2, and whether *Hayes* is enough." }
        model.dismissUndo()
        return model
    }

    private func screen(_ bucket: TaskBucket, _ model: TasksModel, expanded: UUID? = nil, @ViewBuilder _ content: () -> some View) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s3) {
                Image(systemName: bucket.systemImage)
                    .font(Typeface.title)
                    .foregroundStyle(bucket == .today ? theme.accent.color : theme.textSecondary.color)
                Text(bucket.name).font(Typeface.display).foregroundStyle(theme.textPrimary.color)
            }
            .padding(.top, Space.s7)
            .padding(.bottom, Space.s3)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4)
        .overlay(alignment: .bottomTrailing) { QuickAddButton {}.padding(Space.s5) }
    }

    private func rows(_ tasks: [TaskItem], _ bucket: TaskBucket, _ model: TasksModel, expanded: UUID? = nil) -> some View {
        ForEach(tasks) { task in
            TaskRow(model: model, task: task, bucket: bucket, isExpanded: expanded == task.id, onTap: {}, onSchedule: { _ in })
                .padding(.vertical, expanded == task.id ? Space.s2 : 0)
        }
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let model = try await model()

        try write(TasksFront(model: model).padding(.top, Space.s7), name: "tasks-front.png", to: directory)

        try write(screen(.today, model) { rows(model.tasks(in: .today), .today, model) }, name: "tasks-today.png", to: directory)

        let todays = model.tasks(in: .today)
        try write(screen(.today, model) {
            ForEach(TodayPart.allCases) { part in
                let inPart = todays.filter { TaskRules.part(of: $0) == part }
                if !inPart.isEmpty {
                    if let name = part.name { SectionHeading(text: name) }
                    rows(inPart, .today, model)
                }
            }
        }, name: "tasks-today-split.png", to: directory)

        let pack = try #require(model.tasks.first { $0.title.hasPrefix("Pack") })
        try write(screen(.upcoming, model) {
            ForEach(model.upcoming.prefix(6)) { day in
                SectionHeading(text: TaskText.heading(day.day, today: model.today, in: denver), isQuiet: day.isEmpty)
                ForEach(day.events) { EventLine(event: $0, calendar: denver) }
                rows(day.tasks, .upcoming, model)
                rows(day.deadlines, .upcoming, model)
            }
        }, name: "tasks-upcoming.png", to: directory, height: 1100)

        let email = try #require(model.tasks.first { $0.title.hasPrefix("Email Dr. Lee") })
        try write(screen(.today, model) { rows(model.tasks(in: .today), .today, model, expanded: email.id) }, name: "tasks-row-open.png", to: directory, height: 1000)
        try write(screen(.upcoming, model) { rows([pack], .upcoming, model, expanded: pack.id) }, name: "tasks-row-checklist.png", to: directory)

        try write(screen(.anytime, model) { rows(model.tasks(in: .anytime), .anytime, model) }, name: "tasks-anytime.png", to: directory)
        try write(screen(.logbook, model) {
            ForEach(model.logbook()) { day in
                SectionHeading(text: TaskText.heading(day.day, today: model.today, in: denver))
                rows(day.tasks, .logbook, model)
            }
        }, name: "tasks-logbook.png", to: directory)

        // Empty, loading and error.
        let empty = TasksModel(vault: TaskVault(store: MemoryBlobs(), rootKey: try .generate()), calendar: denver, now: { agreed })
        await empty.load()
        try write(screen(.today, empty) { EmptyList(bucket: .today) }, name: "tasks-today-empty.png", to: directory)
        try write(screen(.inbox, empty) { EmptyList(bucket: .inbox) }, name: "tasks-inbox-empty.png", to: directory)
        try write(ProgressView("Opening your tasks").font(Typeface.callout).frame(maxWidth: .infinity, maxHeight: .infinity), name: "tasks-loading.png", to: directory)
        try write(TasksMessage(
            systemImage: "exclamationmark.triangle", title: "Your tasks didn't open",
            detail: "This device's storage couldn't be read. Close Tasks and try again. Nothing has been changed."
        ), name: "tasks-error.png", to: directory)

        // Quick add, understanding as it's typed.
        let typed = "Email Dr. Lee about thesis chapter 2 tomorrow 9am #school !high"
        let parsed = QuickAddParser.parseLines(typed, now: agreed, calendar: denver)
        try write(VStack(alignment: .leading, spacing: Space.s4) {
            Text("New task").font(Typeface.headline).frame(maxWidth: .infinity)
            Text(typed).font(Typeface.body).padding(Space.s4).frame(maxWidth: .infinity, alignment: .leading)
                .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            QuickAddPreview(parsed: parsed, text: typed, model: model)
        }.padding(Space.s4).padding(.top, Space.s5), name: "tasks-quick-add.png", to: directory, height: 420)
        let list = "Outline chapter 3\nEmail advisor tomorrow\nBook MUN hotel #mun due Friday"
        try write(VStack(alignment: .leading, spacing: Space.s4) {
            QuickAddPreview(parsed: QuickAddParser.parseLines(list, now: agreed, calendar: denver), text: list, model: model)
        }.padding(Space.s4).padding(.top, Space.s5), name: "tasks-quick-add-list.png", to: directory, height: 300)

        // The undo bar.
        try write(UndoBar(title: "Submit MUN registration", onUndo: {}, onDismiss: {}).padding(Space.s4).padding(.top, Space.s5),
                  name: "tasks-undo.png", to: directory, height: 140)

        // The home tile, medium and large, as the grid frames it.
        for (size, name, height) in [(BigTileSize.medium, "medium", 176.0), (.large, "large", 270.0), (.square, "square", 380.0)] {
            let entry = ModuleEntry.all.first { $0.id == .tasks }!
            let tile = VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Image(systemName: entry.systemImage)
                    Text(entry.name)
                }
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textSecondary.color)
                TasksHomeTile(model: model, size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(Space.s4)
            .frame(width: 361, height: height)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .padding(Space.s4)
            try write(tile, name: "tasks-tile-\(name).png", to: directory, width: 393, height: height + Space.s6)
        }
        let emptyTile = TasksHomeTile(model: empty, size: .medium).padding(Space.s4).frame(width: 361, height: 176)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)).padding(Space.s4)
        try write(emptyTile, name: "tasks-tile-empty.png", to: directory, width: 393, height: 210)
    }
}
#endif
