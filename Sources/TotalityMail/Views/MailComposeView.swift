#if os(iOS)
import PhotosUI
#endif
import SwiftUI
import TotalityUI
import UniformTypeIdentifiers

/// Writing a message: a new one, a reply, a forward, or a draft picked up again. It saves itself as a
/// draft while it's written, and only a press on Send sends, after a few seconds to Undo.
struct MailComposeView: View {
    private static let bodyHeight = Space.s8 * 4
    private static let mostSuggestions = 5

    @Bindable var composer: MailComposer
    let onClose: () -> Void

    @State private var importing = false
    @State private var confirmingDiscard = false
    @FocusState private var focus: Focus?
    #if os(iOS)
    @State private var photos: [PhotosPickerItem] = []
    #endif

    enum Focus: Hashable {
        case field(MailField), subject, body
    }

    private var title: String {
        switch composer.draft.origin?.kind {
        case .reply: "Reply"
        case .forward: "Forward"
        case nil: "New Message"
        }
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            content
                .background(theme.bg.color)
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(theme.bg.color, for: .navigationBar)
                #endif
                .toolbar { toolbar }
        }
        .tint(theme.accent.color)
        .interactiveDismissDisabled(isBusy)
        .animation(Motion.quick, value: composer.phase)
        .task(id: composer.draft) {
            try? await Task.sleep(for: MailTiming.autosave)
            if !Task.isCancelled { await composer.autosave() }
        }
        .onDisappear {
            Task { await composer.close() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Draft", role: .destructive) {
                Task {
                    await composer.discard()
                    onClose()
                }
            }
        } message: {
            Text("Its words and files are deleted from this device and your others.")
        }
    }

    private var isBusy: Bool {
        switch composer.phase {
        case .holding, .sending: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch composer.phase {
        case .finished(let result):
            MailSendOutcomeView(result: result) { composer.keepWriting() }
        case .discarded:
            Color.clear
        case .writing, .holding, .sending:
            form
                .disabled(composer.phase != .writing)
                .safeAreaInset(edge: .bottom) { sendingBar }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let theme = Theme.current
        switch composer.phase {
        case .writing:
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: onClose)
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Discard", systemImage: "trash") { confirmingDiscard = true }
                    .foregroundStyle(theme.danger.color)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send", systemImage: "paperplane.fill") {
                    Task { await composer.pressSend() }
                }
                .disabled(!composer.canSend)
            }
        case .finished, .discarded:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onClose)
            }
        case .holding, .sending:
            ToolbarItem(placement: .cancellationAction) { EmptyView() }
        }
    }

    // MARK: The form

    private var form: some View {
        let theme = Theme.current
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                if let problem = composer.problem {
                    MailStrip(systemImage: "exclamationmark.triangle", text: problem, isWarning: true)
                }
                // The mailbox's own notes, like a draft that didn't save, sit under this sheet otherwise.
                if let notice = composer.model.notice {
                    MailStrip(systemImage: "info.circle", text: notice)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !composer.senders.isEmpty { fromLine }
                    addressLine(.to)
                    if composer.showsCopies {
                        addressLine(.cc)
                        addressLine(.bcc)
                    }
                }
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))

                TextField("Subject", text: $composer.draft.subject)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .subject)
                    .padding(Space.s3)
                    .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))

                TextEditor(text: $composer.draft.body)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .frame(minHeight: Self.bodyHeight)
                    .padding(Space.s2)
                    .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
                    .accessibilityLabel("Message")

                ForEach(composer.draft.attachments) { file in
                    attachmentRow(file)
                }
                attachButtons

                if let note = composer.routeNote {
                    Label(note.text, systemImage: note.isSealed ? "lock" : "info.circle")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.horizontal, Space.s1)
                }
            }
            .padding(Space.s4)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if composer.draft.to.isEmpty { focus = .field(.to) }
        }
    }

    // MARK: Addresses

    /// Only shown when there's a choice: the Totality address, and each outside account that sends.
    private var fromLine: some View {
        let theme = Theme.current
        return HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text("From")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s6, alignment: .leading)
            Menu {
                Button(composer.model.mailbox.address) { composer.send(from: nil) }
                ForEach(composer.senders, id: \.self) { account in
                    Button(account.address) { composer.send(from: account) }
                }
            } label: {
                HStack(spacing: Space.s1) {
                    Text(composer.fromAddress)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .accessibilityLabel("From \(composer.fromAddress)")
            Spacer(minLength: 0)
        }
        .padding(Space.s3)
    }

    private func addressLine(_ field: MailField) -> some View {
        let theme = Theme.current
        let suggestions = focus == .field(field) ? Array(composer.suggestions(for: field).prefix(Self.mostSuggestions)) : []
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(field.label)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s6, alignment: .leading)
                MailChipFlow(spacing: Space.s2) {
                    ForEach(composer.addresses(field), id: \.self) { address in
                        MailAddressChip(address: address) { composer.remove(address, from: field) }
                    }
                    TextField(composer.addresses(field).isEmpty ? "Name or address" : "", text: typed(field))
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                        .focused($focus, equals: .field(field))
                        .onSubmit { composer.commit(field) }
                        .frame(minWidth: Space.s8 * 2)
                        .accessibilityLabel(field.label)
                }
                if field == .to, !composer.showsCopies {
                    Button("Cc/Bcc") { composer.showsCopies = true }
                        .font(Typeface.caption)
                        .foregroundStyle(theme.accent.color)
                        .buttonStyle(.plain)
                }
            }
            ForEach(suggestions, id: \.self) { person in
                Button {
                    composer.choose(person, for: field)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(person.displayName)
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textPrimary.color)
                        if !person.name.isEmpty {
                            Text(person.address)
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    .padding(.vertical, Space.s1)
                    .padding(.leading, Space.s6 + Space.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("From people in your mail on this device")
            }
        }
        .padding(Space.s3)
        .onChange(of: focus) { old, _ in
            if old == .field(field) { composer.commit(field) }
        }
    }

    private func typed(_ field: MailField) -> Binding<String> {
        Binding {
            composer.typed[field] ?? ""
        } set: { text in
            composer.typed[field] = text
            composer.typing(in: field)
        }
    }

    // MARK: Files

    private func attachmentRow(_ file: MailDraftAttachment) -> some View {
        let theme = Theme.current
        return HStack(spacing: Space.s3) {
            Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Text(Int64(file.data.count).formatted(.byteCount(style: .file)))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            Button {
                composer.removeAttachment(file.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Space.s6, height: Space.s6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(file.name)")
        }
        .padding(Space.s3)
        .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private var attachButtons: some View {
        let theme = Theme.current
        return HStack(spacing: Space.s4) {
            Button("Attach a File", systemImage: "paperclip") { importing = true }
            #if os(iOS)
            PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            .onChange(of: photos) { _, picked in
                guard !picked.isEmpty else { return }
                photos = []
                Task { await attach(picked) }
            }
            #endif
        }
        .font(Typeface.callout)
        .foregroundStyle(theme.accent.color)
        .buttonStyle(.plain)
        .padding(.horizontal, Space.s1)
    }

    private func attach(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                composer.problem = "\(url.lastPathComponent) couldn't be read, so it wasn't attached."
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            composer.attach(name: url.lastPathComponent, mimeType: mime, data: data)
        }
    }

    #if os(iOS)
    private func attach(_ items: [PhotosPickerItem]) async {
        for item in items {
            let kind = item.supportedContentTypes.first ?? .jpeg
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                composer.problem = "A photo couldn't be read, so it wasn't attached."
                continue
            }
            let name = "Photo \(composer.draft.attachments.count + 1).\(kind.preferredFilenameExtension ?? "jpg")"
            composer.attach(name: name, mimeType: kind.preferredMIMEType ?? "application/octet-stream", data: data)
        }
    }
    #endif

    // MARK: Sending

    @ViewBuilder private var sendingBar: some View {
        let theme = Theme.current
        switch composer.phase {
        case .holding:
            HStack(spacing: Space.s3) {
                Text("Sending in a few seconds")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Button("Undo") { composer.undoSend() }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .neumorphic(.raised, in: Capsule())
            .padding(Space.s4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .sending:
            HStack(spacing: Space.s3) {
                ProgressView()
                Text("Sending")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .neumorphic(.raised, in: Capsule())
            .padding(Space.s4)
        default:
            EmptyView()
        }
    }
}

/// Someone on a message being written. One that isn't an address yet shows in the warning colour.
struct MailAddressChip: View {
    let address: MailAddress
    let onRemove: () -> Void

    var body: some View {
        let theme = Theme.current
        let isWrong = !address.isWellFormed
        HStack(spacing: Space.s1) {
            Text(address.displayName)
                .font(Typeface.callout)
                .foregroundStyle(isWrong ? theme.danger.color : theme.textPrimary.color)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(address.displayName)")
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s1)
        .neumorphic(.subtle, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isWrong ? "Not an email address" : address.address)
    }
}

/// Chips left to right, wrapping onto new lines, with the text field taking what's left of the last.
struct MailChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(width: item.width, height: row.height)
                )
            }
        }
    }

    private struct Item {
        let index: Int
        let x: CGFloat
        let width: CGFloat
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [Item] = []
    }

    /// The last subview is the text field, which stretches to the end of its row.
    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row(y: 0)]
        for (index, subview) in subviews.enumerated() {
            let isLast = index == subviews.count - 1
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            var row = rows[rows.count - 1]
            let x = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty, x + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            let start = row.items.isEmpty ? 0 : row.width + spacing
            let itemWidth = isLast && width.isFinite ? max(size.width, width - start) : size.width
            row.items.append(Item(index: index, x: start, width: itemWidth))
            row.width = start + itemWidth
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// How a send went, said plainly for each person. Whoever it didn't reach is still on the draft.
struct MailSendOutcomeView: View {
    let result: MailSendResult
    let onKeepWriting: () -> Void

    private var title: String {
        if result.deliveredToEveryone { return "Sent" }
        return result.sent == nil ? "Not sent" : "Sent to some of them"
    }

    private var summary: String {
        if result.deliveredToEveryone { return "Everyone it was for has it." }
        if result.sent == nil { return "Nobody got it. It's still a draft with everything you wrote, so you can fix it and send it again." }
        return "The people it didn't reach are still on a draft, with everything you wrote."
    }

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                Label(title, systemImage: result.deliveredToEveryone ? "paperplane" : "exclamationmark.triangle")
                    .font(Typeface.title)
                    .foregroundStyle(theme.textPrimary.color)
                Text(summary)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                VStack(alignment: .leading, spacing: Space.s3) {
                    ForEach(Array(result.recipients.enumerated()), id: \.offset) { _, recipient in
                        row(recipient)
                    }
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg))
                if result.sent != nil, !result.keptCopy {
                    MailStrip(systemImage: "iphone", text: MailWording.copyOnDevice)
                }
                if result.sent != nil {
                    Label(MailWording.betweenAccounts, systemImage: "lock")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                if result.remaining != nil {
                    Button("Back to the Draft", systemImage: "square.and.pencil", action: onKeepWriting)
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                        .buttonStyle(.plain)
                        .padding(.top, Space.s2)
                }
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ recipient: MailSendResult.Recipient) -> some View {
        let theme = Theme.current
        let delivered = recipient.outcome == .delivered || recipient.outcome == .sentOutside
        return HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Image(systemName: delivered ? "checkmark.circle" : "exclamationmark.circle")
                .font(Typeface.body)
                .foregroundStyle(delivered ? theme.success.color : theme.danger.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(recipient.address.displayName)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                if !recipient.address.name.isEmpty {
                    Text(recipient.address.address)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                Text(MailWording.outcome(recipient.outcome))
                    .font(Typeface.caption)
                    .foregroundStyle(delivered ? theme.textSecondary.color : theme.danger.color)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
