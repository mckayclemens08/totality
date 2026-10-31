import SwiftUI
import TotalityUI
import UniformTypeIdentifiers

/// Setting up the recovery key, and joining a device to it. The words here are deliberately blunt:
/// this is the one thing in the app that can't be undone by anyone.
struct BackupView: View {
    let model: BackupModel
    @State private var typed = ""
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

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
        .interactiveDismissDisabled(isMidCeremony)
        .task { await model.load() }
        .onChange(of: model.phase) { typed = "" }
        .onDisappear { model.leave() }
    }

    private var isMidCeremony: Bool {
        switch model.phase {
        case .working, .showingKey, .confirmingKey: true
        default: false
        }
    }

    /// Key text fades when the app isn't active, so the app switcher's snapshot doesn't capture it.
    private var keyOpacity: Double {
        scenePhase == .active ? 1 : 0
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
            AccountDetail(text: "Your recovery key is what opens your encrypted content on a new or restored device. Totality doesn't keep it, so once you finish here it can't be shown again.")
            warning
            AccountDetail(text: "This is the first step. Sync isn't finished, so today your recovery key only helps with what's restored from a device backup. Once sync is on, it brings everything back.")
            AccountButton(title: "Create recovery key", isWorking: false) { model.begin() }
        case .showingKey(let key):
            AccountDetail(text: "Save this now, in a password manager and on paper. Don't rely on a screenshot or your Notes.")
            Text(key)
                .font(Typeface.code)
                .foregroundStyle(Theme.current(scheme).textPrimary.color)
                .opacity(keyOpacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.s4)
                .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
            Button("Copy for 2 minutes") { RecoveryKeyClipboard.copy(key) }
                .font(Typeface.callout)
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
        case .confirmingOwnership:
            AccountDetail(text: "This device already has encrypted content on it. Is it yours?")
            AccountDetail(text: "Answering yes ties it to this account for good. If it's someone else's, say no and sign in with their account instead.")
            AccountButton(title: "Yes, it's mine", isWorking: false) { Task { await model.confirmOwnership() } }
            Button("No, it isn't") { model.declineOwnership() }
                .font(Typeface.callout)
        case .otherAccount:
            AccountDetail(text: "The encrypted content on this device belongs to a different account, so a recovery key can't be set up here. Sign in with that account to manage it.")
        case .ready(let copies):
            AccountDetail(text: "Your recovery key is set up, and this device has joined.")
            AccountDetail(text: copiesText(copies))
            AccountDetail(text: "Sync isn't finished, so your notes and events aren't on Totality's servers yet.")
            warning
        }
    }

    private func copiesText(_ copies: BackupCopies) -> String {
        switch (copies.matrix, copies.supabase) {
        case (true, true):
            "A locked copy of your content key is on the Matrix server and in Supabase. Neither can open it."
        case (false, true):
            "A locked copy of your content key is in Supabase, which can't open it. The copy on the Matrix server hasn't saved yet, and will be tried again next time you open this."
        case (true, false):
            "A locked copy of your content key is on the Matrix server, which can't open it. The copy in Supabase hasn't saved yet, and will be tried again next time you open this."
        case (false, false):
            "Neither server has confirmed a copy of your locked key right now. This will be tried again next time you open this."
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
            .opacity(keyOpacity)
            .padding(Space.s4)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

/// Copying a recovery key has to be easy, because a password manager is the best place for it, but
/// it mustn't linger or travel to other devices.
private enum RecoveryKeyClipboard {
    private static let lifetime = Duration.seconds(120)

    @MainActor static func copy(_ key: String) {
        #if os(iOS)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: key]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        #else
        let board = NSPasteboard.general
        board.clearContents()
        // The marker asks clipboard managers and Universal Clipboard to leave it alone.
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(key, forType: .string)
        let change = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: lifetime)
            if board.changeCount == change { board.clearContents() }
        }
        #endif
    }
}
