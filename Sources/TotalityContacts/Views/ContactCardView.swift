import SwiftUI
import TotalityCore
import TotalityUI

/// One card, as on the approved canvas (artboard ContactCard): the face, name and @username, the labels, four
/// actions, the fields, and the line saying where it came from. Call and Text hand the number to the
/// iPhone's own apps; Message and Mail open Totality's, and nothing is sent without the person's press.
struct ContactCardView: View {
    @Bindable var model: ContactsModel
    let id: UUID
    let onClose: () -> Void
    @State private var editing = false
    @State private var sharing = false
    @State private var addingTask = false
    @State private var merging = false
    @State private var linking = false
    @State private var confirmDelete = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            Group {
                if let card = model.card(id) {
                    ScrollView { page(card).padding(Space.s4) }
                        .sheet(isPresented: $editing) {
                            ContactEditor(model: model, original: card) { _ in editing = false }
                        }
                        .sheet(isPresented: $sharing) {
                            ShareCardSheet(model: model, card: card) { sharing = false }
                        }
                        .sheet(isPresented: $addingTask) {
                            AddToTasksSheet(draft: model.taskDraft(for: card), maker: model.taskMaker) { made in
                                addingTask = false
                                if let made { model.notice = made.line }
                            }
                        }
                        .sheet(isPresented: $merging) {
                            MergeSheet(model: model, keep: card) { merging = false }
                        }
                        .sheet(isPresented: $linking) {
                            LinkSheet(model: model, card: card) { linking = false }
                        }
                        .confirmationDialog("Delete \(card.shownName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                Task {
                                    await model.delete(card)
                                    onClose()
                                }
                            }
                        } message: {
                            Text("It stays in Recently Deleted for 30 days, on every device.")
                        }
                } else {
                    ContactsMessage(systemImage: "person.crop.circle.badge.questionmark", title: "This card is gone", detail: "It may have been deleted on another device.")
                }
            }
            .background(theme.bg.color)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: onClose) }
                if let card = model.card(id), !card.isDeleted {
                    ToolbarItem(placement: .primaryAction) { menu(card) }
                    ToolbarItem(placement: .confirmationAction) { Button("Edit") { editing = true } }
                }
            }
        }
        .tint(theme.accent.color)
    }

    private func menu(_ card: ContactCard) -> some View {
        Menu {
            AskTotalityMenuButton(context: AIAskContext(
                id: card.id.uuidString,
                module: .contacts,
                title: card.name,
                detail: [card.company, card.emails.first?.value, card.phones.first?.value]
                    .compactMap { $0 }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                body: card.notes
            ))
            Button(card.isFavourite ? "Remove from Favourites" : "Add to Favourites", systemImage: card.isFavourite ? "star.slash" : "star") {
                Task { await model.toggleFavourite(card) }
            }
            Button("Share card", systemImage: "square.and.arrow.up") { sharing = true }
            if model.taskMaker != nil {
                Button("Add to Tasks", systemImage: "checklist") { addingTask = true }
            }
            if card.username == nil {
                Button("Link to @username", systemImage: "link") { linking = true }
            } else {
                Button("Unlink @\(card.username ?? "")", systemImage: "link.badge.plus") { Task { await model.unlink(card) } }
            }
            Button("Merge with…", systemImage: "arrow.triangle.merge") { merging = true }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private func page(_ card: ContactCard) -> some View {
        let theme = Theme.current
        VStack(spacing: Space.s4) {
            VStack(spacing: Space.s1) {
                PersonFace(photo: card.photo, name: card.shownName, diameter: Space.s8 + Space.s6)
                Text(card.name)
                    .font(Typeface.display)
                    .foregroundStyle(theme.textPrimary.color)
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.s3)
                if !card.nickname.isEmpty, card.nickname != card.name {
                    Text("“\(card.nickname)”")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textSecondary.color)
                }
                if let handle = card.handle {
                    Text("\(handle) · on Totality")
                        .font(Typeface.callout.weight(.semibold))
                        .foregroundStyle(theme.accent.color)
                }
                if !card.company.isEmpty {
                    Text(card.company)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                if !card.labels.isEmpty || card.isFavourite {
                    HStack(spacing: Space.s2) {
                        ForEach(card.labels + (card.isFavourite ? ["Favourite"] : []), id: \.self) { label in
                            Text(label)
                                .font(Typeface.micro)
                                .foregroundStyle(theme.textSecondary.color)
                                .padding(.horizontal, Space.s2)
                                .padding(.vertical, Space.s1)
                                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        }
                    }
                    .padding(.top, Space.s2)
                }
            }
            if card.isDeleted {
                VStack(spacing: Space.s2) {
                    Text("In Recently Deleted, \(model.daysLeft(card)) days left.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                    TileButton("Restore", systemImage: "arrow.uturn.backward", isProminent: true) { Task { await model.restore(card) } }
                }
            } else {
                actions(card)
            }
            if let notice = model.notice {
                NoticeLine(text: notice) { model.notice = nil }
            }
            fields(card)
            Text(footer(card))
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s2)
        }
    }

    // MARK: Actions

    /// Only the actions the card can do: Message and Profile when it's linked to an @username, Mail when it
    /// has an address, Call and Text when it has a number.
    @ViewBuilder
    private func actions(_ card: ContactCard) -> some View {
        let mails = Self.mailAddresses(card)
        let phone = card.phoneNumbers.first
        let handle = card.username
        let count = [handle != nil, !mails.isEmpty, phone != nil, phone != nil, handle != nil].filter { $0 }.count
        if count > 0 {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2), count: count), spacing: Space.s3) {
                if let handle {
                    ActionTile("Message", systemImage: "message", isEnabled: model.onMessage != nil) { model.onMessage?(handle) }
                }
                if mails.count > 1 {
                    Menu {
                        ForEach(mails, id: \.self) { address in Button(address) { model.onMail?([address]) } }
                    } label: { ActionLabel(title: "Mail", systemImage: "envelope", isEnabled: model.onMail != nil) }
                    .buttonStyle(SoftPress())
                    .accessibilityLabel("Mail")
                } else if !mails.isEmpty {
                    ActionTile("Mail", systemImage: "envelope", isEnabled: model.onMail != nil) { model.onMail?(mails) }
                }
                if let phone {
                    ActionTile("Call", systemImage: "phone") { open("tel", phone) }
                    ActionTile("Text", systemImage: "text.bubble") { open("sms", phone) }
                }
                if let handle {
                    ActionTile("Profile", systemImage: "person.crop.circle", isEnabled: model.onProfile != nil) { model.onProfile?(handle) }
                }
            }
        }
    }

    /// Totality Mail first when linked, then the card's own addresses.
    static func mailAddresses(_ card: ContactCard) -> [String] {
        var mails = card.emailAddresses
        if let address = card.totalityAddress, !mails.contains(where: { $0.lowercased() == address }) { mails.insert(address, at: 0) }
        return mails
    }

    /// Hands a number to the iPhone's Phone or Messages app. Only digits and a leading + go in the link.
    private func open(_ scheme: String, _ number: String) {
        let plus = number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        let digits = ContactSearch.digits(number)
        guard !digits.isEmpty, let url = URL(string: "\(scheme):\(plus)\(digits)") else { return }
        openURL(url)
    }

    // MARK: Fields

    @ViewBuilder
    private func fields(_ card: ContactCard) -> some View {
        let rows = fieldRows(card)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    FieldRow(row: row)
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
    }

    private func fieldRows(_ card: ContactCard) -> [FieldRow.Row] {
        var rows: [FieldRow.Row] = []
        for phone in card.phones { rows.append(.init(key: phone.label, value: phone.value)) }
        if let address = card.totalityAddress { rows.append(.init(key: "Totality Mail", value: address, isAccent: true)) }
        for email in card.emails { rows.append(.init(key: email.label, value: email.value)) }
        for place in card.addresses { rows.append(.init(key: place.label, value: place.oneLine)) }
        if let birthday = card.birthday { rows.append(.init(key: "Birthday", value: Birthdays.shown(birthday, in: model.calendar))) }
        if !card.notes.isEmpty { rows.append(.init(key: "Notes", value: card.notes)) }
        return rows
    }

    private func footer(_ card: ContactCard) -> String {
        var parts: [String] = []
        if let origin = card.origin {
            parts.append("Copied from iPhone Contacts on \(Birthdays.dayMonth(origin.copiedAt, in: model.calendar)).")
            if model.twoWaySync { parts.append("Two-way sync is on.") }
        }
        parts.append("End-to-end encrypted. Call and Text open the iPhone's own apps.")
        return parts.joined(separator: " ")
    }
}

/// One of the four big actions on a card.
struct ActionTile: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) { ActionLabel(title: title, systemImage: systemImage, isEnabled: isEnabled) }
            .buttonStyle(SoftPress())
            .disabled(!isEnabled)
    }
}

struct ActionLabel: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s1) {
            Image(systemName: systemImage)
                .font(Typeface.headline)
                .foregroundStyle(isEnabled ? theme.accent.color : theme.textTertiary.color)
            Text(title)
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(isEnabled ? theme.textPrimary.color : theme.textSecondary.color)
        }
        .frame(maxWidth: .infinity, minHeight: Space.s8)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

struct FieldRow: View {
    struct Row: Identifiable {
        let key: String
        let value: String
        var isAccent = false
        var id: String { "\(key)|\(value)" }
    }

    let row: Row

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.hairline) {
            Text(row.key)
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
            Text(row.value)
                .font(Typeface.body)
                .foregroundStyle(row.isAccent ? theme.accent.color : theme.textPrimary.color)
                .textSelection(.enabled)
        }
        .padding(.vertical, Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
