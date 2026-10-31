import SwiftUI
import TotalityUI

/// Setting up the recovery key, and joining a device to it. The words here are deliberately blunt:
/// this is the one thing in the app that can't be undone by anyone.
struct BackupView: View {
    let model: BackupModel
    @State private var typed = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.current(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                content
                if let notice = model.notice {
                    Text(notice)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.danger.color)
                }
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.bg.color)
        .navigationTitle("Recovery key")
        .navigationBarBackButtonHidden(model.phase == .working)
        .interactiveDismissDisabled(model.phase == .working)
        .task { await model.load() }
        .onChange(of: model.phase) { typed = "" }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .checking:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .unavailable:
            AccountDetail(text: "Your backup couldn't be checked. You may be offline.")
            AccountButton(title: "Try again", isWorking: false) { Task { await model.load() } }
        case .notSetUp:
            AccountDetail(text: "Your recovery key is what brings your content back if you lose your devices. Totality will show it once, and it can't be shown again.")
            warning
            AccountDetail(text: "This is the first step. It backs up the key that opens your notes and events. They themselves aren't backed up or synced until sync is finished, so for now they still stay on each device.")
            AccountButton(title: "Create recovery key", isWorking: false) { model.begin() }
        case .showingKey(let key):
            AccountDetail(text: "Save this now, in a password manager and on paper. Don't rely on a screenshot or your Notes.")
            Text(key)
                .font(Typeface.code)
                .foregroundStyle(Theme.current(scheme).textPrimary.color)
                .textSelection(.enabled)
                .privacySensitive()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.s4)
                .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
            warning
            AccountButton(title: "I've saved it", isWorking: false) { model.continueToConfirm() }
            Button("Cancel") { model.cancel() }
                .font(Typeface.callout)
        case .confirmingKey:
            AccountDetail(text: "Enter your recovery key to prove you saved it. Nothing is stored until this matches.")
            keyField
            AccountButton(title: "Finish", isWorking: false) { Task { await model.confirm(typed) } }
            Button("Show the key again") { model.showKeyAgain() }
                .font(Typeface.callout)
        case .working:
            ProgressView("Working. Keep Totality open.")
                .font(Typeface.callout)
                .frame(maxWidth: .infinity)
        case .needsKey:
            AccountDetail(text: "Your account already has a recovery key. Enter it to add this device. Anything already on this device stays, and moves over to the shared key.")
            keyField
            AccountButton(title: "Add this device", isWorking: false) { Task { await model.enter(typed) } }
            warning
        case .ready(let matrixCopy):
            AccountDetail(text: "Your recovery key is set up, and this device has joined.")
            AccountDetail(text: matrixCopy
                ? "A locked copy of your content key is on your Matrix server and in Supabase. Neither can open it."
                : "A locked copy of your content key is in Supabase, which can't open it. The copy on your Matrix server hasn't saved yet, and will be tried again next time you open this.")
            AccountDetail(text: "Your notes and events aren't synced yet, so they still stay on each device.")
            warning
        }
    }

    private var warning: some View {
        Text("If you lose your recovery key and all your devices, your content is gone. Nobody can get it back, including you.")
            .font(Typeface.callout)
            .foregroundStyle(Theme.current(scheme).danger.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var keyField: some View {
        TextField("Recovery key", text: $typed, axis: .vertical)
            .font(Typeface.code)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .privacySensitive()
            .padding(Space.s4)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}
