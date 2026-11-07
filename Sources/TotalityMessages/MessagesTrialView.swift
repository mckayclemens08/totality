import SwiftUI
import TotalityUI

/// The trial's only screen: connect, send one message, and see what arrives. Not the real Messages UI.
public struct MessagesTrialView: View {
    let model: MessagesTrialModel
    let onClose: () -> Void
    @State private var username = ""
    @State private var text = "First end-to-end encrypted message on Totality."

    public init(model: MessagesTrialModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack {
                    Button("Home", action: onClose)
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                    Spacer()
                }
                Text("Messages trial")
                    .font(Typeface.title)
                    .foregroundStyle(theme.textPrimary.color)
                phaseLine
                if case .ready = model.phase {
                    sendForm
                    if let status = model.status {
                        Text(status).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                    received
                }
            }
            .padding(Space.s5)
        }
        .background(theme.bg.color)
        .task { await model.connect() }
    }

    @ViewBuilder private var phaseLine: some View {
        let theme = Theme.current
        switch model.phase {
        case .signedOut, .connecting:
            HStack(spacing: Space.s2) {
                ProgressView()
                Text("Connecting to the Matrix server…").font(Typeface.body)
            }
            .foregroundStyle(theme.textSecondary.color)
        case .ready(let userID, let deviceID):
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Signed in as \(userID)").font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                Text("Device \(deviceID)").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
        case .failed(let reason):
            Text(reason).font(Typeface.body).foregroundStyle(theme.danger.color)
        }
    }

    private var sendForm: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s3) {
            // The @ is already there, so people type only the name.
            HStack(spacing: Space.s1) {
                Text("@").foregroundStyle(theme.textSecondary.color).accessibilityHidden(true)
                TextField("username", text: $username)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Their username")
            }
            .font(Typeface.body)
            .padding(Space.s3)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(Space.s3)
                .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
            Button("Send end-to-end encrypted") {
                Task { await model.send(text, to: username) }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.accent.color)
            .disabled(username.isEmpty || text.isEmpty)
        }
    }

    private var received: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s3) {
            Text("In your chats").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
            if model.messages.isEmpty {
                Text("Nothing yet.").font(Typeface.body).foregroundStyle(theme.textSecondary.color)
            }
            ForEach(model.messages) { message in
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(message.isOwn ? "You" : message.sender)
                        .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    Text(message.body)
                        .font(Typeface.body)
                        .foregroundStyle(message.decrypted ? theme.textPrimary.color : theme.danger.color)
                }
                .padding(Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
                .accessibilityIdentifier("trial.message")
            }
        }
    }
}
