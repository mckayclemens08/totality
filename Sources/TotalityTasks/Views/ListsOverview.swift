import SwiftUI
import TotalityCore
import TotalityUI

/// Every list at once (step 2 canvas, approved 2026-11-18): the six fixed lists as small tiles, the
/// pinned smart lists, then each area with its projects.
struct ListsOverview: View {
    let model: TasksModel
    let onBucket: (TaskBucket) -> Void
    let onList: (UUID) -> Void
    let onNew: (TaskList.Kind) -> Void

    private static let tiles: [[TaskBucket]] = [[.inbox, .today, .upcoming], [.anytime, .someday, .logbook]]

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                RefreshStatusLine(model.refresher)
                ForEach(Self.tiles, id: \.self) { row in
                    HStack(spacing: Space.s3) {
                        ForEach(row) { bucket in tile(bucket) }
                    }
                }
                smartLists
                areasAndProjects
                Color.clear.frame(height: Metric.addButton + Space.s5)
            }
            .padding(.horizontal, Space.s4)
            .padding(.top, Space.s2)
        }
        .background(theme.bg.color)
        .pullsToRefresh(with: model.refresher)
    }

    private func tile(_ bucket: TaskBucket) -> some View {
        let theme = Theme.current
        let count = bucket == .logbook ? 0 : model.count(bucket)
        let isToday = bucket == .today
        return Button { onBucket(bucket) } label: {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack {
                    Image(systemName: bucket.systemImage)
                        .font(Typeface.callout)
                        .foregroundStyle(isToday ? theme.accent.color : theme.textSecondary.color)
                    Spacer(minLength: 0)
                    if count > 0 {
                        Text("\(count)")
                            .font(Typeface.title)
                            .monospacedDigit()
                            .foregroundStyle(isToday ? theme.accent.color : theme.textPrimary.color)
                    }
                }
                Text(bucket.name)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s3)
            .frame(maxWidth: .infinity, minHeight: Space.s8, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(count > 0 ? "\(bucket.name), \(count) tasks" : bucket.name)
    }

    private func groupHeading(_ title: String, trailing: String? = nil) -> some View {
        let theme = Theme.current
        return HStack {
            Text(title).font(Typeface.callout)
            Spacer()
            if let trailing { Text(trailing).font(Typeface.caption) }
        }
        .foregroundStyle(theme.textSecondary.color)
        .padding(.horizontal, Space.s1)
        .padding(.top, Space.s4)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var smartLists: some View {
        let all = model.smartLists
        let pinned = all.filter(\.isPinned)
        let others = all.filter { !$0.isPinned }
        groupHeading("Smart lists", trailing: pinned.isEmpty ? nil : "Pinned")
        VStack(spacing: 0) {
            if all.isEmpty {
                Button { onNew(.smart) } label: {
                    Label("Make a smart list from tags, areas, dates and more", systemImage: "line.3.horizontal.decrease")
                        .font(Typeface.callout.weight(.regular))
                        .foregroundStyle(Theme.current.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.s2)
                }
                .buttonStyle(SoftPress())
            }
            ForEach(pinned + others) { list in
                smartRow(list)
            }
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s1)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }

    private func smartRow(_ list: TaskList) -> some View {
        let theme = Theme.current
        let count = model.tasks(matching: list.rules ?? SmartRules()).count
        return Button { onList(list.id) } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(Typeface.callout)
                    .foregroundStyle(list.isPinned ? theme.accent.color : theme.textSecondary.color)
                    .accessibilityHidden(true)
                Text(list.displayName)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: Space.s2)
                Text("\(count)")
                    .font(Typeface.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary.color)
            }
            .padding(.vertical, Space.s2 + Space.s1 / 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("\(list.displayName), \(count) tasks")
    }

    @ViewBuilder private var areasAndProjects: some View {
        let areas = model.areas
        let unfiled = model.projects(in: nil)
        groupHeading("Areas and projects")
        if areas.isEmpty, unfiled.isEmpty {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Areas hold the ongoing parts of life, like School. Projects finish, like a paper.")
                    .font(Typeface.callout.weight(.regular))
                    .foregroundStyle(Theme.current.textSecondary.color)
                HStack(spacing: Space.s2) {
                    HeaderPill("New area", systemImage: "square.stack") { onNew(.area) }
                    HeaderPill("New project", systemImage: "circle") { onNew(.project) }
                }
            }
            .itemCard()
        }
        ForEach(areas) { area in
            areaCard(area)
        }
        if !unfiled.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(unfiled) { projectRow($0) }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
    }

    private func areaCard(_ area: TaskList) -> some View {
        let theme = Theme.current
        let loose = model.looseTasks(in: area).count
        return VStack(alignment: .leading, spacing: 0) {
            Button { onList(area.id) } label: {
                HStack {
                    Text(area.displayName)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                    Spacer()
                    if loose > 0 {
                        Text("\(loose) loose")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                .padding(.vertical, Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            .accessibilityLabel(loose > 0 ? "\(area.displayName), area, \(loose) loose tasks" : "\(area.displayName), area")
            ForEach(model.projects(in: area.id)) { projectRow($0) }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }

    private func projectRow(_ project: TaskList) -> some View {
        let theme = Theme.current
        let progress = model.projectProgress(of: project)
        let isNear = project.deadline.map { model.today.days(to: $0, in: model.calendar) <= TaskRules.deadlineNear } ?? false
        return Button { onList(project.id) } label: {
            HStack(spacing: Space.s3) {
                TotalityUI.ProgressRing(progress: progress.fraction, diameter: Space.s5)
                Text(project.displayName)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: Space.s2)
                if let deadline = project.deadline {
                    Text(TaskText.day(deadline, today: model.today, in: model.calendar))
                        .font(Typeface.caption)
                        .foregroundStyle(isNear ? theme.danger.color : theme.textSecondary.color)
                }
            }
            .padding(.vertical, Space.s2)
            .padding(.leading, Space.s1)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("\(project.displayName), project, \(progress.done) of \(progress.total) done")
    }
}
