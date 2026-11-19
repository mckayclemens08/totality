import SwiftUI
import TotalityCore
import TotalityUI

// Step 6 (mockup approved 2026-11-18, row "Tasks step 6" on the redesign canvas): the small pieces the
// sharing screens share.

/// Someone's face in a shared list: their profile photo, or their initials.
struct SharedFace: View {
    let shared: SharedListsModel
    let username: String
    var diameter: CGFloat = Space.s5 + Space.s1

    var body: some View {
        PersonFace(photo: shared.photo(of: username), name: username == shared.own ? "Me" : shared.name(of: username), diameter: diameter)
    }
}

/// Overlapping faces, then "You, Priya and Maya".
struct FaceStack: View {
    let shared: SharedListsModel
    let people: [String]
    var diameter: CGFloat = Space.s5 + Space.s1
    var showsNames = true

    var body: some View {
        HStack(spacing: Space.s2) {
            HStack(spacing: -Space.s2) {
                ForEach(people.prefix(5), id: \.self) { SharedFace(shared: shared, username: $0, diameter: diameter) }
            }
            if showsNames {
                Text(Self.names(people.map(shared.shortName(of:))))
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.textSecondary.color)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.names(people.map(shared.name(of:))))
    }

    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

/// The lock and "End-to-end encrypted". Only shown for a room this device checked is encrypted.
struct EncryptedLabel: View {
    var detail: String?

    var body: some View {
        let theme = Theme.current
        Label {
            Text(detail ?? "End-to-end encrypted")
        } icon: {
            Image(systemName: "lock")
        }
        .font(Typeface.caption)
        .foregroundStyle(theme.textSecondary.color)
    }
}

/// A small tag under a task's title: a day, "From Jonah", a list's name.
struct SharedChip: View {
    let text: String
    var systemImage: String?
    var isAccent = false

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s1) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(Typeface.micro)
        .foregroundStyle(isAccent ? theme.accent.color : theme.textSecondary.color)
        .padding(.horizontal, Space.s2)
        .padding(.vertical, Space.s1)
        .background(Capsule().fill(isAccent ? theme.highlight.color : theme.bg.color))
    }
}

/// One task in a shared list, or in Assigned to me.
struct SharedTaskRow: View {
    let shared: SharedListsModel
    let list: SharedListState
    let task: SharedTask
    let model: TasksModel
    var showsList = false
    let onOpen: () -> Void

    var body: some View {
        let theme = Theme.current
        let item = task.task
        let assignee = list.assignee(of: task)
        let canTick = shared.canEdit(list.room)
        HStack(spacing: Space.s3) {
            if canTick {
                TickBox(isDone: item.isCompleted, title: item.displayTitle) {
                    Task { await shared.toggle(item.id, in: list.room) }
                }
            } else {
                TickMark(isDone: item.isCompleted).frame(width: Space.s6, height: Space.s6)
            }
            Button(action: onOpen) {
                HStack(spacing: Space.s3) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(item.displayTitle)
                            .font(Typeface.body)
                            .strikethrough(item.isCompleted)
                            .foregroundStyle(item.isCompleted ? theme.textSecondary.color : theme.textPrimary.color)
                            .multilineTextAlignment(.leading)
                        chips(assignee: assignee)
                    }
                    Spacer(minLength: 0)
                    if let assignee { SharedFace(shared: shared, username: assignee) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            .accessibilityLabel(label(assignee: assignee))
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s3)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    @ViewBuilder private func chips(assignee: String?) -> some View {
        let item = task.task
        let comments = list.comments(on: item.id).count
        let showsAny = showsList || item.when != nil || item.deadline != nil || comments > 0 || (!item.isCompleted && assignee == nil)
        if showsAny, !item.isCompleted {
            HStack(spacing: Space.s1) {
                if showsList, let by = task.assignedBy {
                    SharedChip(text: "From \(shared.shortName(of: by))", isAccent: true)
                }
                if showsList { SharedChip(text: list.displayName) }
                if let when = item.when {
                    SharedChip(text: TaskText.day(when, today: model.today, in: model.calendar), isAccent: !showsList && when <= model.today)
                }
                if let deadline = item.deadline {
                    SharedChip(text: TaskText.deadline(deadline, today: model.today, in: model.calendar), systemImage: "flag")
                }
                if comments > 0 { SharedChip(text: "\(comments)", systemImage: "bubble.left") }
                if !showsList, assignee == nil { SharedChip(text: "Unassigned") }
            }
        }
    }

    private func label(assignee: String?) -> String {
        var parts = [task.task.displayTitle]
        if task.task.isCompleted { parts.append("done") }
        if let assignee { parts.append("assigned to \(shared.name(of: assignee))") }
        if showsList { parts.append("in \(list.displayName)") }
        let comments = list.comments(on: task.id).count
        if comments > 0 { parts.append(comments == 1 ? "1 comment" : "\(comments) comments") }
        return parts.joined(separator: ", ")
    }
}

/// "Assigned to me" at the top of Today: open tasks others gave you in shared lists.
struct AssignedToMeSection: View {
    let shared: SharedListsModel
    let model: TasksModel
    let onOpen: (String, UUID) -> Void

    var body: some View {
        let assigned = shared.assignedToMe
        if !assigned.isEmpty {
            VStack(alignment: .leading, spacing: Space.s3) {
                SectionHeading(text: "Assigned to me")
                ForEach(assigned, id: \.task.id) { entry in
                    SharedTaskRow(shared: shared, list: entry.list, task: entry.task, model: model, showsList: true) {
                        onOpen(entry.list.room, entry.task.id)
                    }
                }
            }
        }
    }
}

/// An invitation on the Lists screen. The list's name, tasks and people are inside the encrypted room, so
/// nothing about it can show until you join.
struct InviteCard: View {
    let shared: SharedListsModel
    let invite: SharedRoomInvite

    var body: some View {
        let theme = Theme.current
        let inviter = invite.inviter.map(shared.name(of:)) ?? "Someone"
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                if let by = invite.inviter { SharedFace(shared: shared, username: by, diameter: Space.s7 - Space.s1) }
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("**\(inviter)** invited you to a shared list")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                    if let by = invite.inviter {
                        Text("@\(by)" + (invite.date.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
            }
            HStack(spacing: Space.s3) {
                Button {
                    Task { await shared.decline(invite) }
                } label: {
                    Text("Decline")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(maxWidth: .infinity, minHeight: Metric.headerButton)
                        .neumorphic(.subtle, in: Capsule())
                }
                .buttonStyle(SoftPress())
                Button {
                    Task { await shared.accept(invite) }
                } label: {
                    Text("Join")
                        .font(Typeface.callout.weight(.semibold))
                        .foregroundStyle(theme.accentOn.color)
                        .frame(maxWidth: .infinity, minHeight: Metric.headerButton)
                        .background(Capsule().fill(theme.accent.color))
                }
                .buttonStyle(SoftPress())
            }
            Text("Its name and tasks are end-to-end encrypted, so they show once you join. Joining shows you this list only: they can't see your other tasks. Declining doesn't tell \(inviter).")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        .itemCard()
    }
}

/// Shared lists and invitations, on the Lists screen.
struct SharedListsSection: View {
    let shared: SharedListsModel
    let onOpen: (String) -> Void

    var body: some View {
        let theme = Theme.current
        if !shared.invites.isEmpty || !shared.lists.isEmpty {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(shared.invites.count == 1 ? "Invitation" : shared.invites.isEmpty ? "Shared" : "Invitations")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.horizontal, Space.s1)
                    .padding(.top, Space.s4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(shared.invites) { InviteCard(shared: shared, invite: $0) }
                if !shared.lists.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(shared.lists) { row($0) }
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s2)
                    .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                }
            }
        }
    }

    private func row(_ list: SharedListState) -> some View {
        let theme = Theme.current
        let others = list.members.filter { $0.username != shared.own && !$0.isInvited }.map(\.username)
        return Button { onOpen(list.room) } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: "person.2")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(list.displayName)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Text("\(list.openCount) open · shared")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                Spacer(minLength: Space.s2)
                FaceStack(shared: shared, people: others, diameter: Space.s5, showsNames: false)
            }
            .padding(.vertical, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("\(list.displayName), shared, \(list.openCount) open")
    }
}
