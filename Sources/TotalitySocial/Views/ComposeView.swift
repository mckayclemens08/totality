import SwiftUI
import TotalityCore
import TotalityUI

/// A new text post. You pick who sees it, each choice with its agreed label, and nothing is sent until
/// you press Post (non-negotiable 6). Photos, video and audio come in later steps of issue 149.
struct ComposeView: View {
    let model: SocialModel
    let onClose: () -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var audience: Audience = .everyone
    @State private var posting = false
    @State private var editingCloseFriends = false

    var body: some View {
        let theme = Theme.current
        let tags = PostTags.find(in: title + " " + text)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack {
                        Button("Cancel", action: onClose).font(Typeface.body).foregroundStyle(theme.textSecondary.color)
                        Spacer()
                        Text("New post").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        Spacer()
                        HeaderPill(posting ? "Posting…" : "Post", isProminent: true) {
                            Task {
                                posting = true
                                if await model.publish(audience, title: title, body: text) { onClose() }
                                posting = false
                            }
                        }
                        .disabled(posting || PostLimits.problem(title: title, body: text) != nil)
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Title").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        TextField("Optional", text: $title).font(Typeface.headline).raisedField()
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Post").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        TextField("What's on your mind? Add #tags anywhere.", text: $text, axis: .vertical)
                            .lineLimit(6...20)
                            .raisedField(.block)
                        HStack {
                            if !tags.isEmpty {
                                Text(tags.map { "#" + $0 }.joined(separator: " ")).foregroundStyle(theme.accent.color)
                            }
                            Spacer()
                            Text("\(text.count) / \(PostLimits.body)")
                                .foregroundStyle(text.count > PostLimits.body ? theme.danger.color : theme.textSecondary.color)
                        }
                        .font(Typeface.caption)
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Who can see this").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        ForEach(Audience.allCases) { choice in
                            AudienceRow(
                                audience: choice, isSelected: audience == choice,
                                isAvailable: !choice.isEncrypted || model.privateReason == nil,
                                count: choice == .closeFriends ? model.closeFriends.count : nil,
                                onEdit: choice == .closeFriends && model.privateReason == nil ? { editingCloseFriends = true } : nil
                            ) { audience = choice }
                        }
                        if let reason = model.privateReason {
                            Text(reason).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        }
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color.ignoresSafeArea())
            .hidesNavigationBar()
            .sheet(isPresented: $editingCloseFriends) { CloseFriendsView(model: model) { editingCloseFriends = false } }
        }
        .interactiveDismissDisabled(!text.isEmpty || !title.isEmpty)
    }
}

/// One audience to choose: its name, who that is, and the label that says how it's kept.
struct AudienceRow: View {
    let audience: Audience
    let isSelected: Bool
    let isAvailable: Bool
    let count: Int?
    let onEdit: (() -> Void)?
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Button(action: action) {
                HStack(spacing: Space.s3) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? theme.accent.color : theme.textTertiary.color)
                        .font(Typeface.title)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(count.map { "\(audience.name) · \($0)" } ?? audience.name)
                            .font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        Text(audience.who).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        Label(audience.label, systemImage: audience.systemImage)
                            .font(Typeface.micro)
                            .foregroundStyle(audience.isEncrypted ? theme.success.color : theme.textSecondary.color)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            .disabled(!isAvailable)
            if let onEdit {
                Button("Edit", action: onEdit).font(Typeface.callout).foregroundStyle(theme.accent.color)
            }
        }
        .padding(Space.s3)
        .selectionWash(isSelected, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .neumorphic(isSelected ? .flat : .subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .opacity(isAvailable ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Close friends, picked from the people you follow. Saving changes who's in your encrypted Close-friends room.
struct CloseFriendsView: View {
    let model: SocialModel
    let onClose: () -> Void
    @State private var chosen: Set<String> = []
    @State private var saving = false

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Button("Cancel", action: onClose).foregroundStyle(theme.textSecondary.color)
                Spacer()
                Text("Close friends").font(Typeface.headline)
                Spacer()
                HeaderPill(saving ? "Saving…" : "Save", isProminent: true) {
                    Task {
                        saving = true
                        if await model.setCloseFriends(chosen) { onClose() }
                        saving = false
                    }
                }
                .disabled(saving)
            }
            Text("Only people on this list see your Close-friends posts. People on the list can see who else is on it, and so can Totality's server.")
                .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            if model.followingSet.isEmpty {
                EmptyFeed(systemImage: "person.2", title: "Follow people first", detail: "Close friends are chosen from the people you follow.")
            }
            ScrollView {
                VStack(spacing: Space.s2) {
                    ForEach(model.followingSet.sorted(), id: \.self) { name in
                        Button {
                            if chosen.contains(name) { chosen.remove(name) } else { chosen.insert(name) }
                        } label: {
                            HStack(spacing: Space.s3) {
                                PersonFace(photo: model.photos[name], name: name, diameter: Space.s6)
                                Text(Handle.display(name)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                Spacer()
                                Image(systemName: chosen.contains(name) ? "star.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(name) ? theme.accent.color : theme.textTertiary.color)
                            }
                            .padding(Space.s3)
                            .toggleSurface(chosen.contains(name), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }
                        .buttonStyle(SoftPress())
                        .accessibilityAddTraits(chosen.contains(name) ? .isSelected : [])
                    }
                }
            }
        }
        .padding(Space.s4)
        .background(theme.bg.color.ignoresSafeArea())
        .onAppear { chosen = model.closeFriends }
    }
}
