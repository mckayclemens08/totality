import SwiftUI
import TotalityCore
import TotalityUI

/// The Ask Totality sheet / module view (issue 252).
public struct AIHomeView: View {
    @Bindable private var model: AIModel
    private let initialAbout: AIContextItem?
    private let onClose: (() -> Void)?

    @State private var prompt = ""
    @State private var showingAccess = false
    @State private var showingActivity = false
    @State private var showingModel = false
    @State private var editingProposalID: UUID?
    @State private var editedBody = ""

    public init(model: AIModel, about: AIContextItem? = nil, onClose: (() -> Void)? = nil) {
        self.model = model
        self.initialAbout = about
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(spacing: 0) {
                header
                privacyBanner
                Divider().overlay(theme.shadowDark.color.opacity(0.2))
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s4) {
                        if let about = initialAbout {
                            aboutChip(about)
                            if model.messages.isEmpty {
                                quickPromptsRow(for: about)
                            }
                        }
                        if model.messages.isEmpty, !model.hasAnyGrant {
                            emptyGrantState
                        } else if model.messages.isEmpty {
                            readyEmptyState
                        }
                        ForEach(model.messages) { message in
                            messageRow(message)
                        }
                        if model.phase == .thinking {
                            thinkingCard
                        }
                        if let missing = model.missingGrant {
                            missingPermissionCard(for: missing)
                        }
                        if !model.localModelStatus.isReady {
                            modelNoticeCard
                        }
                    }
                    .padding(Space.s4)
                }
                composerBar
            }
            .background(theme.bg.color)
            .navigationBarBackButtonHidden(true)
            .sheet(isPresented: $showingAccess) {
                AIAccessView(model: model) { showingAccess = false }
            }
            .sheet(isPresented: $showingActivity) {
                AIActivityView(model: model) { showingActivity = false }
            }
            .sheet(isPresented: $showingModel) {
                AIModelView(model: model) { showingModel = false }
            }
            .alert("Ask Totality", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("OK", role: .cancel) { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
        }
        .edgeSwipeBack(onClose)
        .task { await model.load() }
    }

    private var header: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s2) {
            if let onClose {
                HeaderButton("Back", systemImage: "chevron.left", action: onClose)
            }
            Text("Ask Totality")
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
            Spacer(minLength: 0)
            HeaderButton("Activity log", systemImage: "clock.arrow.circlepath") { showingActivity = true }
            HeaderButton("Access", systemImage: "hand.raised") { showingAccess = true }
            HeaderButton("Model and privacy", systemImage: "cpu") { showingModel = true }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s3)
        .padding(.bottom, Space.s2)
    }

    private var privacyBanner: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s2) {
            Image(systemName: "lock.shield")
                .foregroundStyle(theme.success.color)
                .accessibilityHidden(true)
            Text("Runs on this iPhone. Nothing leaves the device.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4)
        .padding(.bottom, Space.s2)
    }

    private func aboutChip(_ item: AIContextItem) -> some View {
        let theme = Theme.current
        return Text("About: \(item.title)\(item.detail.isEmpty ? "" : " · \(item.detail)")")
            .font(Typeface.caption.weight(.semibold))
            .foregroundStyle(theme.accent.color)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(theme.highlight.color, in: Capsule())
    }

    private func quickPromptsRow(for item: AIContextItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(Self.quickPrompts(for: item.module), id: \.self) { text in
                    HeaderPill(text, systemImage: "sparkles") {
                        Task { await model.ask(text, about: item) }
                    }
                }
            }
            .padding(.vertical, Space.s1)
        }
    }

    private static func quickPrompts(for module: ModuleID) -> [String] {
        switch module {
        case .mail: ["Summarize this email", "Draft a reply", "Add task from this"]
        case .messages: ["Summarize this message", "Add task from this"]
        case .reader, .web: ["Summarize this", "Save a note", "Add task from this"]
        case .calendar: ["Check my schedule", "Add task for this"]
        case .tasks: ["Schedule this tomorrow", "What else is due?"]
        case .social: ["Summarize this post", "Add task from this"]
        default: ["Summarize this", "Add task from this"]
        }
    }

    private var emptyGrantState: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s3) {
            Image(systemName: "sparkles")
                .font(Typeface.title)
                .foregroundStyle(theme.accent.color)
                .accessibilityHidden(true)
            Text("It can't see anything yet")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Choose which modules it may read, and which ones it may suggest changes in. Anything it wants to send, post or delete always asks you first.")
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HeaderPill("Choose what it can use", systemImage: "slider.horizontal.3", isProminent: true) {
                showingAccess = true
            }
        }
        .itemCard()
    }

    private var readyEmptyState: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text("Ready on this iPhone")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Ask about your granted modules, summarize what you missed, or draft a reply or task for your OK.")
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .itemCard()
    }

    @ViewBuilder
    private func messageRow(_ message: AIMessage) -> some View {
        let theme = Theme.current
        if message.role == .user {
            HStack {
                Spacer(minLength: Space.s5)
                VStack(alignment: .trailing, spacing: Space.s1) {
                    if let about = message.aboutLabel {
                        Text("About: \(about)")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Text(message.text)
                        .font(Typeface.body)
                        .foregroundStyle(theme.accentOn.color)
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s3)
                        .background(theme.accent.color, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s3) {
                ForEach(message.sourcesRead) { usage in
                    HStack(spacing: Space.s2) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(theme.success.color)
                            .accessibilityHidden(true)
                        Text(usage.label)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                Text(message.text)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .itemCard()
                if let proposal = message.proposal {
                    proposalCard(messageID: message.id, proposal: proposal)
                }
            }
        }
    }

    private func proposalCard(messageID: UUID, proposal: AIProposedAction) -> some View {
        let theme = Theme.current
        let isEditing = editingProposalID == messageID
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text(proposal.title)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: 0)
                Text(statusBadge(proposal.status))
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(statusColor(proposal.status, theme: theme))
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, Space.s1 / 2)
                    .background(theme.highlight.color, in: Capsule())
            }
            if let recipient = proposal.recipientOrTarget {
                Text("To \(recipient)" + (proposal.subtitle.map { " · \($0)" } ?? ""))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            if isEditing {
                TextEditor(text: $editedBody)
                    .font(Typeface.body)
                    .frame(minHeight: 96)
                    .padding(Space.s2)
                    .background(theme.surface.color, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            } else {
                Text(proposal.body)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if proposal.status == .pending {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s2) {
                        HeaderPill(proposal.kind.requiresExplicitSendWarning ? "Approve and send" : "Approve", isProminent: true) {
                            let overrideBody = isEditing ? editedBody : nil
                            editingProposalID = nil
                            Task { await model.approve(messageID: messageID, editedBody: overrideBody) }
                        }
                        HeaderPill(isEditing ? "Cancel edit" : "Edit") {
                            if isEditing {
                                editingProposalID = nil
                            } else {
                                editedBody = proposal.body
                                editingProposalID = messageID
                            }
                        }
                        Button("Not now") {
                            editingProposalID = nil
                            Task { await model.decline(messageID: messageID) }
                        }
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textSecondary.color)
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        HeaderPill(proposal.kind.requiresExplicitSendWarning ? "Approve and send" : "Approve", isProminent: true, expands: true) {
                            let overrideBody = isEditing ? editedBody : nil
                            editingProposalID = nil
                            Task { await model.approve(messageID: messageID, editedBody: overrideBody) }
                        }
                        HStack(spacing: Space.s2) {
                            HeaderPill(isEditing ? "Cancel edit" : "Edit") {
                                if isEditing {
                                    editingProposalID = nil
                                } else {
                                    editedBody = proposal.body
                                    editingProposalID = messageID
                                }
                            }
                            Button("Not now") {
                                editingProposalID = nil
                                Task { await model.decline(messageID: messageID) }
                            }
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                }
            }
        }
        .itemCard()
    }

    private func statusBadge(_ status: AIProposedAction.Status) -> String {
        switch status {
        case .pending: "Needs your OK"
        case .approved: "Approved"
        case .declined: "Declined"
        }
    }

    private func statusColor(_ status: AIProposedAction.Status, theme: Theme) -> Color {
        switch status {
        case .pending: theme.accent.color
        case .approved: theme.success.color
        case .declined: theme.textSecondary.color
        }
    }

    private var thinkingCard: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            ProgressView()
            Text("Thinking on this iPhone…")
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
            HeaderPill("Stop") { model.stopThinking() }
        }
        .itemCard()
    }

    private func missingPermissionCard(for module: ModuleID) -> some View {
        let theme = Theme.current
        let name = model.grants[module]?.name ?? module.rawValue.capitalized
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text("\(name) is turned off")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("To help with \(name.lowercased()), it needs Read access on \(name).")
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HeaderPill("Allow Read on \(name)", isProminent: true) {
                Task { await model.setGrant(module, scope: .read, to: true) }
            }
        }
        .itemCard()
    }

    @ViewBuilder
    private var modelNoticeCard: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            switch model.localModelStatus {
            case .downloading(let progress):
                Text("Downloading on-device model…")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                ProgressView(value: progress)
                    .tint(theme.accent.color)
                HStack {
                    Text("Qwen 2.5 1.5B · \(Int((progress * 100).rounded()))% of ~1.0 GB")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    HeaderPill("Cancel") { model.cancelModelDownload() }
                }
            case .failed(let message):
                Text("Couldn't download local model")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.danger.color)
                Text(message)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s2) {
                        HeaderPill("Retry download", isProminent: true) {
                            Task { await model.downloadLocalModel() }
                        }
                        HeaderPill("Model details") { showingModel = true }
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        HeaderPill("Retry download", isProminent: true, expands: true) {
                            Task { await model.downloadLocalModel() }
                        }
                        HeaderPill("Model details", expands: true) { showingModel = true }
                    }
                }
            default:
                Text("Running in quick-summary mode")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text("Download Qwen 2.5 1.5B (~1.0 GB via llama.cpp) for full conversational answers offline on this device. Nothing ever leaves your phone.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s2) {
                        HeaderPill("Download model (~1.0 GB)", isProminent: true) {
                            Task { await model.downloadLocalModel() }
                        }
                        HeaderPill("Model details") { showingModel = true }
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        HeaderPill("Download model (~1.0 GB)", isProminent: true, expands: true) {
                            Task { await model.downloadLocalModel() }
                        }
                        HeaderPill("Model details", expands: true) { showingModel = true }
                    }
                }
            }
        }
        .itemCard()
    }

    private var composerBar: some View {
        let theme = Theme.current
        let canSend = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.phase != .thinking
        return HStack(spacing: Space.s2) {
            TextField("Ask", text: $prompt)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .raisedField(.line)
                .onSubmit { sendPrompt() }
            HeaderPill("Send", systemImage: "arrow.up", isProminent: true, iconOnly: true, action: sendPrompt)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.5)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .background(theme.bg.color)
    }

    private func sendPrompt() {
        let text = prompt
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prompt = ""
        Task { await model.ask(text, about: initialAbout) }
    }
}
