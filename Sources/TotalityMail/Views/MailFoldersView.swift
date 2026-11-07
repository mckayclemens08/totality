import SwiftUI
import TotalityUI

/// Every place mail can be, with the person's own folders after the built-in ones.
struct MailFoldersView: View {
    let model: MailModel
    let onChoose: () -> Void

    @State private var naming: FolderName?
    @State private var typed = ""
    @State private var removing: MailOwnFolder?
    @State private var editingSignature = false
    @State private var editingOutside = false

    private struct FolderName: Identifiable {
        let id = UUID()
        var folder: MailOwnFolder?
    }

    private func systemImage(_ place: MailPlace) -> String {
        switch place {
        case .folder(.inbox): "tray"
        case .starred: "star"
        case .folder(.sent): "paperplane"
        case .folder(.drafts): "doc"
        case .folder(.archive): "archivebox"
        case .folder(.spam): "exclamationmark.octagon"
        case .folder(.trash): "trash"
        case .folder(.own): "folder"
        }
    }

    private func ownFolder(_ place: MailPlace) -> MailOwnFolder? {
        guard case .folder(.own(let id)) = place else { return nil }
        return model.mailbox.settings.folders.first { $0.id == id }
    }

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s1) {
                if !model.mailbox.address.isEmpty {
                    AddressLine("Your address", address: model.mailbox.address)
                        .padding(.horizontal, Space.s3)
                        .padding(.bottom, Space.s2)
                }
                ForEach(model.mailbox.places, id: \.self) { place in
                    row(place)
                }
                Button {
                    typed = ""
                    naming = FolderName()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                        .padding(Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    editingSignature = true
                } label: {
                    Label("Signature", systemImage: "signature")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textPrimary.color)
                        .padding(Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.outside != nil {
                    Button {
                        editingOutside = true
                    } label: {
                        Label("Outside Accounts", systemImage: "person.crop.circle.badge.plus")
                            .font(Typeface.callout)
                            .foregroundStyle(theme.textPrimary.color)
                            .padding(Space.s3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Space.s3)
        }
        .background(theme.bg.color)
        .sheet(isPresented: $editingSignature) {
            MailSignatureView(model: model) { editingSignature = false }
                #if os(macOS)
                .frame(minWidth: Space.s8 * 6, minHeight: Space.s8 * 5)
                #endif
        }
        .sheet(isPresented: $editingOutside) {
            if let outside = model.outside {
                OutsideAccountsView(model: outside) { editingOutside = false }
                    #if os(macOS)
                    .frame(minWidth: Space.s8 * 7, minHeight: Space.s8 * 7)
                    #endif
            }
        }
        .alert(naming?.folder == nil ? "New Folder" : "Rename Folder", isPresented: isNaming) {
            TextField("Folder name", text: $typed)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(removing?.name ?? "this folder")?", isPresented: isRemoving, titleVisibility: .visible, presenting: removing) { folder in
            Button("Remove Folder", role: .destructive) {
                Task { await model.remove(folder) }
            }
        } message: { _ in
            Text("Its mail moves to Archive, so nothing is lost.")
        }
    }

    private var isNaming: Binding<Bool> {
        Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private func save() {
        let name = typed
        let folder = naming?.folder
        Task {
            if let folder {
                await model.rename(folder, to: name)
            } else {
                await model.addFolder(named: name)
            }
        }
    }

    private func row(_ place: MailPlace) -> some View {
        let theme = Theme.current
        let isCurrent = model.place == place
        let unread = model.mailbox.unreadCount(in: place)
        return Button {
            model.place = place
            onChoose()
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: systemImage(place))
                    .font(Typeface.body)
                    .foregroundStyle(isCurrent ? theme.accent.color : theme.textSecondary.color)
                    .frame(width: Space.s5)
                    .accessibilityHidden(true)
                Text(model.mailbox.name(of: place))
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if unread > 0 {
                    Text("\(unread)")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .accessibilityLabel("\(unread) unread")
                }
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if isCurrent {
                    Color.clear.neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            if let folder = ownFolder(place) {
                Button("Rename", systemImage: "pencil") {
                    typed = folder.name
                    naming = FolderName(folder: folder)
                }
                Button("Remove Folder", systemImage: "folder.badge.minus", role: .destructive) { removing = folder }
            }
        }
    }
}

/// The signature under new messages. It's a setting, so it's sealed and syncs with the rest.
struct MailSignatureView: View {
    private static let editorHeight = Space.s8 * 2

    let model: MailModel
    let onDone: () -> Void

    @State private var text = ""

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Written under each new message, reply, and forward. Leave it empty for none.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                TextEditor(text: $text)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: Self.editorHeight)
                    .padding(Space.s2)
                    .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
                    .accessibilityLabel("Signature")
                Spacer(minLength: 0)
            }
            .padding(Space.s4)
            .background(theme.bg.color)
            .navigationTitle("Signature")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let signature = text
                        Task { await model.setSignature(signature) }
                        onDone()
                    }
                }
            }
        }
        .tint(theme.accent.color)
        .onAppear { text = model.mailbox.settings.signature }
    }
}
