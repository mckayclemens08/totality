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
        let vault = TaskVault(store: MemoryBlobs(), rootKey: try .generate())
        let school = TaskList(name: "School", kind: .area, createdAt: agreed)
        let mun = TaskList(name: "MUN", kind: .area, createdAt: agreed)
        try await vault.save(school)
        try await vault.save(mun)
        let model = TasksModel(vault: vault, calendar: denver, now: { agreed })
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
        for task in model.tasks {
            if task.tags.contains("school") || task.title.hasPrefix("Reading response") { await model.change(task.id) { $0.listID = school.id } }
            if task.tags.contains("mun") { await model.change(task.id) { $0.listID = mun.id } }
        }
        let email = try #require(model.tasks.first { $0.title.hasPrefix("Email Dr. Lee") })
        await model.change(email.id) { $0.notes = "Ask about the **corpus** for chapter 2, and whether *Hayes* is enough." }
        model.dismissUndo()
        return model
    }

    private func screen(_ bucket: TaskBucket, _ model: TasksModel, expanded: UUID? = nil, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ScreenTitle(bucket.name)
                .padding(.top, Space.s7)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4)
        .overlay(alignment: .bottomTrailing) { AddButton("New task") {}.padding(Space.s4) }
    }

    private func rows(_ tasks: [TaskItem], _ bucket: TaskBucket, _ model: TasksModel, expanded: UUID? = nil) -> some View {
        ForEach(tasks) { task in
            TaskRow(model: model, task: task, bucket: bucket, isExpanded: expanded == task.id, onTap: {}, onSchedule: { _ in })
                .padding(.vertical, Space.s1 + Space.s1 / 2)
        }
    }

    @Test func render() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOTALITY_RENDER_DIR"] else { return }
        let model = try await model()

        try write(screen(.today, model) {
            TodayProgressView(progress: model.progress)
            rows(model.tasks(in: .today), .today, model)
        }, name: "tasks-front.png", to: directory)

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
            Text(typed).font(Typeface.body).frame(maxWidth: .infinity, alignment: .leading)
                .raisedField()
            QuickAddPreview(parsed: parsed, text: typed, model: model)
        }.padding(Space.s4).padding(.top, Space.s5), name: "tasks-quick-add.png", to: directory, height: 420)
        let list = "Outline chapter 3\nEmail advisor tomorrow\nBook MUN hotel #mun due Friday"
        try write(VStack(alignment: .leading, spacing: Space.s4) {
            QuickAddPreview(parsed: QuickAddParser.parseLines(list, now: agreed, calendar: denver), text: list, model: model)
        }.padding(Space.s4).padding(.top, Space.s5), name: "tasks-quick-add-list.png", to: directory, height: 300)

        // Every Tasks text box in the raised-capsule look. ImageRenderer can't draw a live text field on the
        // Mac, so each is drawn as its words inside the same raisedField() the real fields use.
        let theme = Theme.current
        let quiet = theme.textSecondary.color
        try write(VStack(alignment: .leading, spacing: Space.s3) {
            Text("Quick add").font(Typeface.caption).foregroundStyle(quiet)
            Text("Email Dr. Lee about chapter 2 tomorrow 9am #thesis").font(Typeface.body).foregroundStyle(quiet)
                .frame(maxWidth: .infinity, alignment: .leading).raisedField()
            Text("An open task").font(Typeface.caption).foregroundStyle(quiet).padding(.top, Space.s3)
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Pack for the MUN conference").font(Typeface.body).frame(maxWidth: .infinity, alignment: .leading).raisedField()
                Text("Hotel is the Marriott on 5th. Check in after 3.").font(Typeface.callout.weight(.regular))
                    .frame(maxWidth: .infinity, alignment: .leading).raisedField(.block)
                ForEach([("Country placard", true), ("Blazer", false), ("Laptop charger", false)], id: \.0) { item, done in
                    HStack(spacing: Space.s1) {
                        TickMark(isDone: done, diameter: Space.s4).frame(width: Space.s6, height: Space.s6)
                        Text(item).font(Typeface.callout.weight(.regular)).foregroundStyle(done ? quiet : theme.textPrimary.color)
                        Spacer()
                        Image(systemName: "xmark").font(Typeface.micro).foregroundStyle(quiet).frame(width: Space.s6, height: Space.s6)
                    }
                    .padding(.horizontal, -Space.s2)
                    .raisedField()
                }
                HStack(spacing: Space.s1) {
                    Image(systemName: "plus").font(Typeface.micro).foregroundStyle(quiet).frame(width: Space.s6, height: Space.s6)
                    Text("Add to checklist").font(Typeface.callout.weight(.regular)).foregroundStyle(quiet)
                    Spacer()
                }
                .padding(.horizontal, -Space.s2)
                .raisedField()
                FlowRow {
                    ChipLabel(systemImage: "calendar", text: "Thursday")
                    ChipLabel(systemImage: "flag", text: "Deadline")
                    ChipLabel(systemImage: "exclamationmark", text: "Priority")
                }
                FlowRow {
                    HStack(spacing: Space.s1) { Text("#mun"); Image(systemName: "xmark").font(Typeface.micro) }
                        .font(Typeface.caption).foregroundStyle(quiet)
                        .padding(.horizontal, Space.s2).padding(.vertical, Space.s1)
                        .neumorphic(.subtle, in: Capsule())
                    HStack(spacing: Space.s1) {
                        Image(systemName: "number").font(Typeface.micro).foregroundStyle(quiet)
                        Text("Add tag").font(Typeface.callout.weight(.regular)).foregroundStyle(quiet)
                    }
                    .raisedField()
                }
            }
            .padding(Space.s3)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            Text("Logbook search").font(Typeface.caption).foregroundStyle(quiet).padding(.top, Space.s3)
            // SearchBox's look, with Text standing in for its TextField, which ImageRenderer can't draw.
            HStack(spacing: Space.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textSecondary.color)
                Text("Search the Logbook").foregroundStyle(theme.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .raisedField()
        }.padding(Space.s4).padding(.top, Space.s5), name: "tasks-fields.png", to: directory, height: 1000)

        // The undo bar.
        try write(UndoBar(title: "Submit MUN registration", onUndo: {}, onDismiss: {}).padding(Space.s4).padding(.top, Space.s5),
                  name: "tasks-undo.png", to: directory, height: 140)

        try tiles(model, prefix: "tasks-tile", to: directory)
        let emptyTile = TasksHomeTile(model: empty, size: .medium).frame(width: 358, height: 172)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)).padding(Space.s4)
        try write(emptyTile, name: "tasks-tile-empty.png", to: directory, width: 393, height: 210)

        // Today's progress, after two of today's tasks are done.
        for title in ["Read Hayes", "Pick up blazer"] {
            let task = try #require(model.tasks.first { $0.title.hasPrefix(title) })
            await model.toggle(task.id)
        }
        model.dismissUndo()
        try write(screen(.today, model) {
            TodayProgressView(progress: model.progress).padding(.bottom, Space.s4)
            rows(model.tasks(in: .today), .today, model)
        }, name: "tasks-progress-today.png", to: directory)
        try tiles(model, prefix: "tasks-progress-tile", to: directory)
    }

    private func tiles(_ model: TasksModel, prefix: String, to directory: String) throws {
        // The home tile, medium and large, as the grid frames it.
        for (size, name, height) in [(TileSize.small, "small", 172.0), (.medium, "medium", 172.0), (.large, "large", 358.0)] {
            let tile = TasksHomeTile(model: model, size: size)
            .frame(width: size == .small ? 172 : 358, height: height)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .padding(Space.s4)
            try write(tile, name: "\(prefix)-\(name).png", to: directory, width: 393, height: height + Space.s6)
        }
    }
}
#endif
