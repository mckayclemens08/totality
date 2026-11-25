import SwiftUI
import TotalityCore
import TotalityUI

/// Messages › Who can message me (issue 149 §4). The choice is the accent card; the others are raised.
struct MessagePrivacyView: View {
    let model: MessagesModel
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("Who can message me")
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textSecondary.color)
                    VStack(spacing: Space.s3) {
                        ForEach(MessageReach.allCases) { choice in
                            ReachChoice(choice: choice, isOn: model.reach == choice) {
                                Task { await model.setReach(choice) }
                            }
                        }
                    }
                    .disabled(model.reach == nil)
                    if model.reach == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    Text("Everyone else can send you a request. A request says only who it's from, and their first message waits until you accept. Chats you already have keep working. The same setting is in Social › Safety.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                    if let notice = model.notice {
                        Text(notice).font(Typeface.caption).foregroundStyle(theme.danger.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Privacy")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
        .tint(theme.accent.color)
        .task { await model.loadPrivacy() }
    }
}

private struct ReachChoice: View {
    let choice: MessageReach
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? theme.accentOn.color : theme.textTertiary.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(choice.title)
                        .font(Typeface.headline)
                        .foregroundStyle(isOn ? theme.accentOn.color : theme.textPrimary.color)
                    Text(choice.detail)
                        .font(Typeface.caption)
                        .foregroundStyle(isOn ? theme.accentOn.color : theme.textSecondary.color)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(theme.accent.color)
                }
            }
            .neumorphic(isOn ? .subtle : .raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Someone asking to message you, among the requests on the chat list.
struct MessageRequestRow: View {
    let request: MessageRequest
    let model: MessagesModel

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Initial(name: request.username)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("@\(request.username)")
                        .font(Typeface.headline)
                        .foregroundStyle(theme.textPrimary.color)
                    Text("Wants to message you. Nothing they write arrives until you accept.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            HStack(spacing: Space.s5) {
                Button("Accept") { Task { await model.accept(request) } }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                Button("Delete") { Task { await model.decline(request) } }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
            }
            .buttonStyle(.plain)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

/// Offered when someone's setting doesn't include you yet.
struct RequestOffer: View {
    let model: MessagesModel
    @State private var sending = false

    var body: some View {
        let theme = Theme.current
        if let username = model.needsRequest {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("@\(username) hasn't let you message them yet. Send a request, and you can chat once they accept.")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                HStack(spacing: Space.s5) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send request") {
                            sending = true
                            Task {
                                await model.sendRequest()
                                sending = false
                            }
                        }
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                    }
                    Button("Not now") { model.needsRequest = nil }
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textPrimary.color)
                }
                .buttonStyle(.plain)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        } else if let username = model.sentRequestTo {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text("Request sent. When @\(username) accepts, the chat opens here for you both.")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: 0)
                Button("OK") { model.sentRequestTo = nil }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
        }
    }
}
