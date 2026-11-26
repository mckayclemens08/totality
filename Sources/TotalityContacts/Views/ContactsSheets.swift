import SwiftUI
import TotalityCore
import TotalityUI

/// A sheet with a title, Done or Cancel, and the background, the same in every one of Contacts' sheets.
struct ContactsSheet<Content: View, Action: View>: View {
    let title: String
    let cancel: String
    let onCancel: () -> Void
    @ViewBuilder let action: () -> Action
    @ViewBuilder let content: () -> Content

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) { content() }
                    .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(cancel, action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { action() }
            }
        }
        .tint(theme.accent.color)
    }
}

/// A raised list of rows, as on the canvas.
struct RowsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s1)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

// MARK: Search

/// Search across names, numbers, addresses and notes, on this device (tiles hold no text fields, so the
/// tile's Search opens this too).
public struct ContactSearchSheet: View {
    let model: ContactsModel
    let onDone: (ContactCard?) -> Void
    @State private var query = ""

    public init(model: ContactsModel, onDone: @escaping (ContactCard?) -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        let found = query.isEmpty ? [] : ContactSearch.filter(model.live, query: query)
        ContactsSheet(title: "Search contacts", cancel: "Done", onCancel: { onDone(nil) }, action: { EmptyView() }) {
            SearchBox("Name, number, address or note", text: $query)
            if !query.isEmpty, found.isEmpty {
                Text("No contacts match “\(query)”.")
                    .font(Typeface.caption)
                    .foregroundStyle(Theme.current.textSecondary.color)
            }
            if !found.isEmpty {
                RowsCard {
                    ForEach(found) { card in
                        Button { onDone(card) } label: {
                            ContactRow(card: card, summary: ContactSearch.summary(card, upcoming: model.upcoming(for: card), calendar: model.calendar))
                        }
                        .buttonStyle(SoftPress())
                    }
                }
            }
            Text("Search runs on this iPhone. Nothing you type is sent.")
                .font(Typeface.micro)
                .foregroundStyle(Theme.current.textSecondary.color)
        }
    }
}

// MARK: Recently Deleted

struct RecentlyDeletedSheet: View {
    let model: ContactsModel
    let onDone: () -> Void
    @State private var confirmEmpty = false
    @State private var forever: ContactCard?

    var body: some View {
        let theme = Theme.current
        ContactsSheet(title: "Recently Deleted", cancel: "Done", onCancel: onDone) {
            Button("Empty") { confirmEmpty = true }
                .disabled(model.deleted.isEmpty)
        } content: {
            Text("Cards stay here for 30 days, on every device, then they're gone for good.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            if model.deleted.isEmpty {
                Text("Nothing here.")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.top, Space.s5)
                    .frame(maxWidth: .infinity)
            } else {
                RowsCard {
                    ForEach(model.deleted) { card in
                        HStack(spacing: Space.s3) {
                            PersonFace(photo: card.photo, name: card.shownName, diameter: Space.s6 + Space.s1)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(card.shownName)
                                    .font(Typeface.body.weight(.semibold))
                                    .foregroundStyle(theme.textPrimary.color)
                                Text(deletedLine(card))
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.textSecondary.color)
                            }
                            Spacer(minLength: 0)
                            TileButton("Restore", systemImage: "arrow.uturn.backward", isProminent: true) { Task { await model.restore(card) } }
                        }
                        .frame(minHeight: Space.s7 + Space.s1)
                        .contextMenu {
                            Button("Delete now", systemImage: "trash", role: .destructive) { forever = card }
                        }
                    }
                }
                Text("Empty asks first, and can't be undone.")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .confirmationDialog("Delete \(model.deleted.count) for good?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete for good", role: .destructive) { Task { await model.deleteForever(model.deleted.map(\.id)) } }
        } message: {
            Text("They'll be gone from every device. This can't be undone.")
        }
        .confirmationDialog("Delete \(forever?.shownName ?? "") for good?", isPresented: Binding(get: { forever != nil }, set: { if !$0 { forever = nil } }), titleVisibility: .visible) {
            Button("Delete for good", role: .destructive) {
                if let forever { Task { await model.deleteForever([forever.id]) } }
            }
        } message: {
            Text("It'll be gone from every device. This can't be undone.")
        }
    }

    private func deletedLine(_ card: ContactCard) -> String {
        let days = model.daysLeft(card)
        let when = card.deletedAt.map { Birthdays.dayMonth($0, in: model.calendar) } ?? ""
        return "Deleted \(when) · \(days) \(days == 1 ? "day" : "days") left"
    }
}

// MARK: Settings: Update from iPhone and two-way sync

struct ContactsSettingsSheet: View {
    @Bindable var model: ContactsModel
    let onDone: () -> Void
    @State private var updates: [ContactUpdate]?
    @State private var chosen: Set<UUID> = []
    @State private var isChecking = false

    var body: some View {
        let theme = Theme.current
        ContactsSheet(title: "Contacts settings", cancel: "Done", onCancel: onDone) {
            if let updates, !updates.isEmpty {
                Button("Save \(chosen.count)") {
                    Task {
                        await model.apply(updates.filter { chosen.contains($0.id) })
                        self.updates = nil
                    }
                }
                .disabled(chosen.isEmpty)
            }
        } content: {
            Text("Update from iPhone")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            if model.device == nil || model.deviceAccess == .denied || model.deviceAccess == .notAsked {
                Text("Totality can't see your iPhone contacts. You can still add contacts here, or allow access in Settings.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                if model.deviceAccess == .denied { OpenSettingsButton() }
            } else if let updates {
                if updates.isEmpty {
                    Text("Nothing changed in iPhone Contacts since you copied your cards.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                } else {
                    Text("\(updates.count) \(updates.count == 1 ? "card" : "cards") changed in iPhone Contacts since you copied them. Nothing is saved until you press Save.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                    RowsCard {
                        ForEach(updates) { update in
                            Button {
                                if chosen.contains(update.id) { chosen.remove(update.id) } else { chosen.insert(update.id) }
                            } label: {
                                HStack(alignment: .top, spacing: Space.s3) {
                                    Image(systemName: chosen.contains(update.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(update.id) ? theme.accent.color : theme.textSecondary.color)
                                    VStack(alignment: .leading, spacing: Space.s1) {
                                        Text(update.card.shownName)
                                            .font(Typeface.body.weight(.semibold))
                                            .foregroundStyle(theme.textPrimary.color)
                                        ForEach(update.changes, id: \.self) { line in
                                            Text(line)
                                                .font(Typeface.caption)
                                                .foregroundStyle(theme.accent.color)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, Space.s2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(SoftPress())
                            .accessibilityAddTraits(chosen.contains(update.id) ? .isSelected : [])
                        }
                    }
                }
            } else {
                TileButton(isChecking ? "Checking…" : "Check iPhone Contacts", systemImage: "arrow.triangle.2.circlepath", isProminent: true) {
                    Task {
                        isChecking = true
                        let found = await model.pendingUpdates()
                        chosen = Set(found.map(\.id))
                        updates = found
                        isChecking = false
                    }
                }
                .disabled(isChecking)
            }
            Toggle(isOn: $model.twoWaySync) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Two-way sync")
                        .font(Typeface.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary.color)
                    Text("Edits here also change iPhone Contacts, and changes there come in here, for cards copied from this iPhone.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .tint(theme.accent.color)
            .itemCard()
            .disabled(model.device == nil || model.deviceAccess == .denied || model.deviceAccess == .notAsked)
            Text("Your Totality notes, labels and @username links are never written to the iPhone. Contacts you didn't share with Totality stay unseen.")
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
            DiscoveryNote()
        }
    }
}

/// Why there's no "Who's on Totality?" yet: discovery waits for a design that never uploads the address book.
struct DiscoveryNote: View {
    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Who's on Totality?")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Totality won't check your address book against other people until it can do that without uploading it. For now, link a card by hand: open it, then More, then Link to @username, or Add to Contacts on someone's profile.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
        }
        .itemCard()
    }
}

// MARK: Import

struct ImportSheet: View {
    let model: ContactsModel
    let contacts: [DeviceContact]
    let onDone: () -> Void
    @State private var chosen: Set<String>

    init(model: ContactsModel, contacts: [DeviceContact], onDone: @escaping () -> Void) {
        self.model = model
        self.contacts = contacts
        self.onDone = onDone
        _chosen = State(initialValue: Set(contacts.map(\.id)))
    }

    var body: some View {
        let theme = Theme.current
        ContactsSheet(title: "Choose contacts", cancel: "Cancel", onCancel: onDone) {
            Button("Copy \(chosen.count)") {
                let picked = contacts.filter { chosen.contains($0.id) }
                onDone()
                Task { await model.copy(picked) }
            }
            .disabled(chosen.isEmpty)
        } content: {
            Text("Totality copies the contacts you choose and encrypts them on this iPhone. Their iPhone notes aren't copied.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            HStack(spacing: Space.s2) {
                TileButton("Select all", systemImage: "checkmark.circle") { chosen = Set(contacts.map(\.id)) }
                TileButton("Select none", systemImage: "circle") { chosen = [] }
            }
            RowsCard {
                ForEach(contacts) { contact in
                    Button {
                        if chosen.contains(contact.id) { chosen.remove(contact.id) } else { chosen.insert(contact.id) }
                    } label: {
                        HStack(spacing: Space.s3) {
                            Image(systemName: chosen.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(contact.id) ? theme.accent.color : theme.textSecondary.color)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(contact.name)
                                    .font(Typeface.body.weight(.semibold))
                                    .foregroundStyle(theme.textPrimary.color)
                                if let line = contact.phones.first?.value ?? contact.emails.first?.value {
                                    Text(line)
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textSecondary.color)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: Space.s7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPress())
                    .accessibilityAddTraits(chosen.contains(contact.id) ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: Merge

struct MergeSheet: View {
    let model: ContactsModel
    let keep: ContactCard
    let onDone: () -> Void
    @State private var query = ""
    @State private var other: ContactCard?
    @State private var keepsMine = true

    var body: some View {
        let theme = Theme.current
        ContactsSheet(title: other == nil ? "Merge with…" : "Merge 2 cards", cancel: "Cancel", onCancel: onDone) {
            if let other {
                Button("Merge") {
                    Task {
                        if keepsMine { await model.merge(keep: keep, other: other) } else { await model.merge(keep: other, other: keep) }
                        onDone()
                    }
                }
            }
        } content: {
            if let other {
                Text("Everything from both is kept. Where both have a name, pick one.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                HStack(spacing: Space.s3) {
                    choice(keep, isOn: keepsMine) { keepsMine = true }
                    choice(other, isOn: !keepsMine) { keepsMine = false }
                }
                let preview = keepsMine ? ContactMerge.merge(keep: keep, other: other, at: model.now) : ContactMerge.merge(keep: other, other: keep, at: model.now)
                RowsCard {
                    ForEach(preview.phones) { FieldRow(row: .init(key: $0.label, value: $0.value)) }
                    ForEach(preview.emails) { FieldRow(row: .init(key: $0.label, value: $0.value)) }
                    ForEach(preview.addresses) { FieldRow(row: .init(key: $0.label, value: $0.oneLine)) }
                    if !preview.labels.isEmpty { FieldRow(row: .init(key: "Labels", value: preview.labels.joined(separator: " · "))) }
                    if !preview.notes.isEmpty { FieldRow(row: .init(key: "Notes", value: preview.notes)) }
                }
                Text("The other card goes to Recently Deleted, so a wrong merge can be undone.")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
            } else {
                SearchBox("Find the other card", text: $query)
                RowsCard {
                    ForEach(ContactSearch.filter(model.live, query: query).filter { $0.id != keep.id }.prefix(40)) { card in
                        Button { other = card } label: {
                            ContactRow(card: card, summary: ContactSearch.summary(card, upcoming: nil, calendar: model.calendar))
                        }
                        .buttonStyle(SoftPress())
                    }
                }
            }
        }
    }

    private func choice(_ card: ContactCard, isOn: Bool, action: @escaping () -> Void) -> some View {
        let theme = Theme.current
        return Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Name")
                    .font(Typeface.micro)
                    .foregroundStyle(theme.textSecondary.color)
                Text(card.name)
                    .font(Typeface.body.weight(.semibold))
                    .foregroundStyle(theme.textPrimary.color)
                Text(card.handle ?? (card.origin != nil ? "From iPhone" : "Totality"))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionWash(isOn, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .neumorphic(isOn ? .flat : .raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(SoftPress())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: Link to @username

struct LinkSheet: View {
    let model: ContactsModel
    let card: ContactCard
    let onDone: () -> Void
    @State private var typed = ""
    @State private var problem: String?
    @State private var isChecking = false

    var body: some View {
        let theme = Theme.current
        ContactsSheet(title: "Link to @username", cancel: "Cancel", onCancel: onDone) {
            Button("Link") { Task { await link() } }
                .disabled(isChecking || typed.trimmingCharacters(in: .whitespaces).isEmpty)
        } content: {
            Text("Link \(card.shownName)'s card to their Totality profile. Then Message, Mail and Profile reach them on Totality.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            TextField("@username", text: $typed)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { Task { await link() } }
                .raisedField()
            if let problem {
                Text(problem)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.danger.color)
            }
            Text("Totality's server learns only that you looked up this profile, as when anyone opens one. The link itself stays inside the encrypted card.")
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    private func link() async {
        isChecking = true
        defer { isChecking = false }
        switch await model.link(card, to: typed) {
        case .linked: onDone()
        case .notAHandle: problem = "A username is 3 to 24 letters, numbers or underscores."
        case .noProfile: problem = "There's no profile you can see at that username."
        case .unavailable: problem = "Profiles couldn't be checked. You may be offline. Try again."
        }
    }
}

// MARK: Share

struct ShareCardSheet: View {
    let model: ContactsModel
    let card: ContactCard
    let onDone: () -> Void
    @State private var options = VCard.Options()
    @State private var file: URL?

    var body: some View {
        let theme = Theme.current
        ContactsSheet(title: "Share card", cancel: "Done", onCancel: done) {
            if let file {
                ShareLink(item: file) { Text("Share") }
            }
        } content: {
            Text("A shared card is a plain vCard file: whoever gets it can read it. The share sheet shows where it goes.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            VStack(spacing: Space.s3) {
                Toggle("Include my notes", isOn: $options.notes)
                Toggle("Include labels", isOn: $options.labels)
                Toggle("Include the photo", isOn: $options.photo).disabled(card.photo == nil)
            }
            .tint(theme.accent.color)
            .itemCard()
            if let file {
                ShareLink(item: file) {
                    Label("Share \(card.shownName)", systemImage: "square.and.arrow.up")
                        .font(Typeface.callout.weight(.semibold))
                        .foregroundStyle(theme.accentOn.color)
                        .frame(maxWidth: .infinity, minHeight: Space.s7)
                        .background(Capsule().fill(theme.accent.color))
                }
                .buttonStyle(SoftPress())
            }
        }
        .task(id: options) { file = model.vCardFile(card, options: options) }
    }

    /// The file is plain, so it doesn't stay in the temporary folder once the sheet closes.
    private func done() {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        onDone()
    }
}
