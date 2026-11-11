import SwiftUI
import TotalityUI

/// Mail's front screen. A narrow window, which is every iPhone, shows one thing at a time. A wide one
/// shows folders, the list, and the open conversation side by side.
public struct MailHomeView: View {
    /// Wide enough for three columns to each stay readable.
    private static let wideWidth = Space.s8 * 13
    private static let foldersWidth = Space.s8 * 3.5
    private static let listWidth = Space.s8 * 5.5

    @Bindable private var model: MailModel
    private let onClose: (() -> Void)?
    private let onOpenLink: (URL) -> Void

    @State private var opened: UUID?
    @State private var showingFolders = false
    @State private var composing: MailComposer?

    public init(model: MailModel, onClose: (() -> Void)? = nil, onOpenLink: @escaping (URL) -> Void = { _ in }) {
        self.model = model
        self.onClose = onClose
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        let theme = Theme.current
        GeometryReader { proxy in
            let isWide = proxy.size.width >= Self.wideWidth
            NavigationStack {
                content(isWide: isWide)
                    .background(theme.bg.color)
                    .edgeSwipeBack(onClose)
                    .toolbar { toolbar(isWide: isWide) }
                    .navigationTitle(model.placeName)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(theme.bg.color, for: .navigationBar)
                    #endif
                    .navigationDestination(item: isWide ? .constant(nil) : $opened) { id in
                        conversationPage(id)
                    }
            }
            .tint(theme.accent.color)
            .overlay(alignment: .bottom) { bottomBar }
            .animation(Motion.quick, value: model.undo)
            .animation(Motion.quick, value: model.notice)
        }
        .sheet(isPresented: $showingFolders) {
            NavigationStack {
                MailFoldersView(model: model) { showingFolders = false }
                    .navigationTitle("Mailboxes")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingFolders = false }
                        }
                    }
            }
            .tint(theme.accent.color)
            #if os(macOS)
            .frame(minWidth: Space.s8 * 6, minHeight: Space.s8 * 8)
            #endif
        }
        .sheet(item: $composing) { composer in
            MailComposeView(composer: composer) { composing = nil }
                #if os(macOS)
                .frame(minWidth: Space.s8 * 8, minHeight: Space.s8 * 9)
                #endif
        }
        // The app keeps Mail up to date before it's opened (`MailModule.refreshAhead`), so opening it
        // fetches nothing. Only a model that has never loaded loads here.
        .task { if model.phase == .loading(nil) { await model.refresh() } }
        .task(id: model.undo?.id) {
            guard let shown = model.undo?.id else { return }
            try? await Task.sleep(for: MailTiming.undo)
            if !Task.isCancelled { model.dismissUndo(shown) }
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: MailTiming.notice)
            if !Task.isCancelled { model.notice = nil }
        }
        .onChange(of: model.place) { opened = nil }
        .onChange(of: model.requestedConversation, initial: true) { openRequested() }
        .onChange(of: model.phase) { openRequested() }
    }

    /// A conversation tapped on the home page opens straight away, once it's in the mailbox.
    private func openRequested() {
        guard let id = model.requestedConversation, model.phase == .ready else { return }
        model.requestedConversation = nil
        if model.mailbox.conversation(id, in: .inbox) != nil { opened = id }
    }

    @ViewBuilder private func content(isWide: Bool) -> some View {
        switch model.phase {
        case .noKey:
            MailStateView(
                systemImage: "lock.slash", title: "Your key isn't on this device",
                detail: "Mail is sealed with a key made from your content key, so it can't open here yet. Add your recovery key in Account, then come back."
            )
            .overlay(alignment: .top) { MailSampleNote(model: model) }
        case .failed:
            MailStateView(
                systemImage: "exclamationmark.triangle", title: "Your mail didn't open",
                detail: "Totality couldn't reach your mailbox, and nothing on this device has changed.",
                action: MailStateAction(label: "Try again") { Task { await model.refresh() } }
            )
            .overlay(alignment: .top) { MailSampleNote(model: model) }
        case .noAccount:
            MailStateView(
                systemImage: "person.crop.circle.badge.questionmark", title: "Sign in to read your mail",
                detail: "Mail opens for the account this device's key belongs to. Sign in with that account in Account, then come back."
            )
        case .waitingForBackup:
            MailStateView(
                systemImage: "key", title: "Mail starts once your recovery key is set up",
                detail: "Your address can only ever have one key, so Totality waits until this device's key is backed up before giving it out. Set up your recovery key in Account, and mail starts arriving here.",
                address: model.mailbox.address
            )
        case .keyConflict:
            MailStateView(
                systemImage: "exclamationmark.lock", title: "There's a problem with your mailbox",
                detail: "Your address is already held by a different key, so mail sent to it can't open on this device. Trying again won't change that. It has to be put right on Totality's server."
            )
        // While Mail opens, its mailbox shows straight away, with a line saying what's under way.
        case .ready, .loading:
            if isWide {
                HStack(spacing: 0) {
                    MailFoldersView(model: model) {}
                        .frame(width: Self.foldersWidth)
                    list.frame(width: Self.listWidth)
                    Group {
                        if let opened, model.mailbox.conversation(opened, in: model.place) != nil {
                            conversationPage(opened).id(opened)
                        } else {
                            MailStateView(systemImage: "envelope", title: "No conversation open", detail: "Pick one from the list to read it here.")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        MailListView(model: model, opened: opened, onOpen: { opened = $0.id }, onWrite: { composing = $0 })
            .searchable(text: $model.query, prompt: "Search mail on this device")
    }

    private func conversationPage(_ id: UUID) -> some View {
        MailConversationView(id: id, model: model, onOpenLink: onOpenLink, onWrite: { composing = $0 }) { opened = nil }
    }

    /// Each side is one item of fixed-size icons (ToolbarIcon), so the buttons sit together instead of iPhone giving
    /// each its own wide slot. Home and Mailboxes go left, as places; writing and selecting go right.
    @ToolbarContentBuilder private func toolbar(isWide: Bool) -> some ToolbarContent {
        let ready = model.phase == .ready
        if onClose != nil || (ready && !isWide) {
            ToolbarItem(placement: .cancellationAction) {
                HStack(spacing: Space.s3) {
                    if let onClose {
                        ToolbarIcon("Home", systemImage: "circle.hexagongrid.fill", action: onClose)
                    }
                    if ready && !isWide {
                        ToolbarIcon("Mailboxes", systemImage: "tray.2.fill") { showingFolders = true }
                    }
                }
            }
        }
        if ready {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: Space.s3) {
                    ToolbarIcon("New Message", systemImage: "square.and.pencil", isEnabled: !model.isSelecting) {
                        composing = .new(in: model)
                    }
                    if model.isSelecting {
                        Button("Done") { model.endSelecting() }
                            .font(Typeface.headline)
                    } else {
                        ToolbarIcon("Select", systemImage: "checkmark.circle.fill", isEnabled: !model.conversations.isEmpty) {
                            model.beginSelecting()
                        }
                    }
                }
            }
        }
    }

    /// Undo and anything short the screens have to say sit in one place, above the action bar.
    @ViewBuilder private var bottomBar: some View {
        let theme = Theme.current
        Group {
            if let notice = model.notice {
                Text(notice)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s3)
                    .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
            } else if let undo = model.undo {
                HStack(spacing: Space.s3) {
                    Text(undo.label)
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                    Button("Undo") { Task { await model.undoLast() } }
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .neumorphic(.raised, in: Capsule())
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.bottom, Space.s8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
