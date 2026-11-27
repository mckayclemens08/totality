import SwiftUI
import TotalityCore
import TotalityUI
#if canImport(UIKit)
import UIKit
#endif

/// Send something from another module to chats, as on the approved share-to-chat canvas (2026-11-26): people, groups
/// and channels you can post to in one grid, pick up to ten, add a note, send. It goes as an end-to-end encrypted
/// message holding only the item's ID.
public struct ShareToChatSheet: View {
    let model: MessagesModel
    let request: ShareRequest
    let onDone: () -> Void
    @State private var query = ""
    @State private var selected: [String] = []
    @State private var note = ""
    @State private var postable: Set<String> = []
    @State private var sending = false
    @State private var failures: [String: String] = [:]
    @State private var copied = false

    public init(model: MessagesModel, request: ShareRequest, onDone: @escaping () -> Void) {
        self.model = model
        self.request = request
        self.onDone = onDone
    }

    public var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack {
                    Text("Send to").font(Typeface.title).foregroundStyle(theme.textPrimary.color)
                    Spacer()
                    Text(selected.isEmpty ? "" : "\(selected.count) selected")
                        .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                }
                SearchBox("Search chats and people", text: $query)
                if targets.isEmpty {
                    Text(query.isEmpty ? "You have no chats yet. Start one in Messages first." : "No chats match.")
                        .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        .frame(maxWidth: .infinity).padding(.vertical, Space.s4)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2, alignment: .top), count: 4), spacing: Space.s3) {
                        ForEach(targets) { chat in cell(chat) }
                    }
                }
                preview
                TextField("Add a note (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .raisedField()
                    .disabled(sending)
                if selected.count >= ShareLimits.maxTargets {
                    Text("You can send to \(ShareLimits.maxTargets) chats at a time.")
                        .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                }
                ForEach(failures.sorted(by: { $0.key < $1.key }), id: \.key) { id, reason in
                    Text("\(name(of: id)) didn't get it. \(reason)")
                        .font(Typeface.caption).foregroundStyle(theme.danger.color)
                }
                Button(action: send) {
                    HStack(spacing: Space.s2) {
                        if sending { ProgressView() } else { Image(systemName: "paperplane") }
                        Text(sendLabel)
                    }
                    .font(Typeface.headline)
                    .foregroundStyle(canSend ? theme.accentOn.color : theme.textTertiary.color)
                    .frame(maxWidth: .infinity, minHeight: Space.s7)
                    .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(canSend ? theme.accent.color : theme.surface.color))
                    .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .buttonStyle(SoftPress())
                .disabled(!canSend)
                links
            }
            .padding(Space.s4)
        }
        .background(theme.bg.color.ignoresSafeArea())
        .task { postable = await model.postableChannels() }
    }

    // MARK: Parts

    private var preview: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            PersonFace(photo: nil, name: request.authorName, diameter: Space.s6 + Space.s2)
            VStack(alignment: .leading, spacing: 0) {
                Text(request.authorName).font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.textPrimary.color).lineLimit(1)
                Text(request.snippet.isEmpty ? "Post" : request.snippet).font(Typeface.micro).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s2)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending a post by \(request.authorName)")
    }

    @ViewBuilder private var links: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            HStack(spacing: Space.s3) {
                Button { copyLink() } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: "link")
                        .font(Typeface.callout)
                        .foregroundStyle(request.link == nil ? theme.textTertiary.color : theme.textPrimary.color)
                        .frame(maxWidth: .infinity, minHeight: Space.s7)
                        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .buttonStyle(SoftPress())
                .disabled(request.link == nil)
                if let link = request.link {
                    ShareLink(item: link) {
                        Label("More...", systemImage: "square.and.arrow.up")
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textPrimary.color)
                            .frame(maxWidth: .infinity, minHeight: Space.s7)
                            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    .buttonStyle(SoftPress())
                }
            }
            if let reason = request.linkReason {
                Text(reason).font(Typeface.micro).foregroundStyle(theme.textSecondary.color).multilineTextAlignment(.center)
            }
        }
    }

    private func cell(_ chat: ChatSummary) -> some View {
        let theme = Theme.current
        let isOn = selected.contains(chat.id)
        let title = name(of: chat)
        return Button { toggle(chat.id) } label: {
            VStack(spacing: Space.s1) {
                ZStack(alignment: .topTrailing) {
                    avatar(chat, title: title)
                        .overlay { if isOn { Circle().stroke(theme.accent.color, lineWidth: 3) } }
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(Typeface.micro.weight(.bold))
                            .foregroundStyle(theme.accentOn.color)
                            .frame(width: Space.s5 - Space.s1, height: Space.s5 - Space.s1)
                            .background(Circle().fill(theme.accent.color))
                            .offset(x: Space.s1, y: -Space.s1)
                    }
                }
                Text(title)
                    .font(isOn ? Typeface.micro.weight(.bold) : Typeface.micro)
                    .foregroundStyle(isOn ? theme.accent.color : theme.textSecondary.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .disabled(sending)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder private func avatar(_ chat: ChatSummary, title: String) -> some View {
        let theme = Theme.current
        if let person = chat.otherPerson {
            PersonFace(photo: model.people.profile(ofMatrixID: person)?.photo, name: title)
        } else if chat.isChannel {
            Image(systemName: "megaphone.fill")
                .foregroundStyle(theme.accent.color)
                .frame(width: Space.s7, height: Space.s7)
                .neumorphic(.raised, in: Circle())
        } else {
            GroupAvatar(title: chat.title, location: chat.photo, messages: model)
        }
    }

    // MARK: Logic

    private var targets: [ChatSummary] {
        model.shareTargets
            .filter { !$0.isChannel || postable.contains($0.id) }
            .filter { query.isEmpty || name(of: $0).localizedCaseInsensitiveContains(query) }
    }

    private func name(of chat: ChatSummary) -> String {
        chat.otherPerson.flatMap { model.people.profile(ofMatrixID: $0)?.name } ?? chat.title
    }

    private func name(of id: String) -> String {
        model.shareTargets.first { $0.id == id }.map(name(of:)) ?? "A chat"
    }

    private var canSend: Bool { ShareLimits.canSend(selected: selected.count) && !sending }

    private var sendLabel: String {
        selected.isEmpty ? "Choose who to send to" : failures.isEmpty ? "Send to \(selected.count)" : "Try again"
    }

    private func toggle(_ id: String) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else if selected.count < ShareLimits.maxTargets {
            selected.append(id)
        }
        failures[id] = nil
    }

    private func send() {
        guard canSend else { return }
        sending = true
        let chats = selected
        Task {
            let result = await model.share(request, note: note, to: chats)
            sending = false
            failures = result.failed
            // Chats that got it leave the picker's selection, so Try again only goes to the ones that didn't.
            selected.removeAll { result.sent.contains($0) }
            if result.allSent { onDone() }
        }
    }

    private func copyLink() {
        guard let link = request.link else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = link.absoluteString
        #endif
        copied = true
    }
}
