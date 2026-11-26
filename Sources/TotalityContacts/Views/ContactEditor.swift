import PhotosUI
import SwiftUI
import TotalityCore
import TotalityUI

/// Making or editing a card. Every text box is the raised field; nothing saves until Save.
struct ContactEditor: View {
    let model: ContactsModel
    let original: ContactCard?
    let onDone: (ContactCard?) -> Void
    @State private var card: ContactCard
    @State private var hasBirthday: Bool
    @State private var birthdayDate: Date
    @State private var knowsYear: Bool
    @State private var newLabel = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isSaving = false

    init(model: ContactsModel, original: ContactCard?, onDone: @escaping (ContactCard?) -> Void) {
        self.model = model
        self.original = original
        self.onDone = onDone
        let start = original ?? ContactCard(phones: [.init(label: "Mobile", value: "")], emails: [.init(label: "Email", value: "")], createdAt: model.now)
        _card = State(initialValue: start)
        _hasBirthday = State(initialValue: start.birthday != nil)
        _knowsYear = State(initialValue: start.birthday?.year != nil)
        let birthday = start.birthday.flatMap { Birthdays.date(of: $0, in: $0.year ?? 2000, calendar: model.calendar) }
        _birthdayDate = State(initialValue: birthday ?? model.calendar.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? Date())
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    photo
                    section("Name") {
                        field("First name", text: $card.givenName)
                        field("Last name", text: $card.familyName)
                        field("Nickname", text: $card.nickname)
                        field("Company", text: $card.company)
                    }
                    section("Phone") {
                        ForEach($card.phones) { $phone in
                            labelled($phone.label, value: $phone.value, prompt: "Phone number", kind: .phone) {
                                card.phones.removeAll { $0.id == phone.id }
                            }
                        }
                        TileButton("Add phone", systemImage: "plus") { card.phones.append(.init(label: card.phones.isEmpty ? "Mobile" : "Home", value: "")) }
                    }
                    section("Email") {
                        ForEach($card.emails) { $email in
                            labelled($email.label, value: $email.value, prompt: "Email address", kind: .email) {
                                card.emails.removeAll { $0.id == email.id }
                            }
                        }
                        TileButton("Add email", systemImage: "plus") { card.emails.append(.init(label: "Email", value: "")) }
                    }
                    section("Address") {
                        ForEach($card.addresses) { $place in
                            VStack(alignment: .leading, spacing: Space.s2) {
                                HStack {
                                    TextField("Label", text: $place.label).raisedField()
                                    removeButton { card.addresses.removeAll { $0.id == place.id } }
                                }
                                TextField("Street", text: $place.street, axis: .vertical).raisedField()
                                TextField("City", text: $place.city).raisedField()
                                HStack(spacing: Space.s2) {
                                    TextField("State", text: $place.region).raisedField()
                                    TextField("Postcode", text: $place.postcode).raisedField()
                                }
                                TextField("Country", text: $place.country).raisedField()
                            }
                        }
                        TileButton("Add address", systemImage: "plus") { card.addresses.append(.init()) }
                    }
                    section("Birthday") {
                        Toggle("Birthday", isOn: $hasBirthday.animation())
                            .tint(theme.accent.color)
                        if hasBirthday {
                            Toggle("I know the year", isOn: $knowsYear)
                                .tint(theme.accent.color)
                            DatePicker("Day", selection: $birthdayDate, displayedComponents: .date)
                        }
                    }
                    section("Labels") {
                        if !card.labels.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Space.s2) {
                                    ForEach(card.labels, id: \.self) { label in
                                        FilterPill("\(label)  ✕", isSelected: true) { card.labels.removeAll { $0 == label } }
                                            .accessibilityLabel("Remove label \(label)")
                                    }
                                }
                                .padding(Space.s2)
                            }
                        }
                        let unused = model.labels.filter { label in !card.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
                        if !unused.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Space.s2) {
                                    ForEach(unused, id: \.self) { label in
                                        FilterPill(label, isSelected: false) { card.labels.append(label) }
                                    }
                                }
                                .padding(Space.s2)
                            }
                        }
                        HStack(spacing: Space.s2) {
                            TextField("New label, such as Family", text: $newLabel)
                                .onSubmit(addLabel)
                                .raisedField()
                            TileButton("Add", systemImage: "tag") { addLabel() }
                                .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    section("Notes") {
                        TextField("Your notes, such as what you talked about", text: $card.notes, axis: .vertical)
                            .lineLimit(3...10)
                            .raisedField(.block)
                        Text("Notes stay in Totality. They're never written to iPhone Contacts.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(original == nil ? "New contact" : "Edit contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || isBlank)
                }
            }
            .onChange(of: photoItem) {
                guard let photoItem else { return }
                Task {
                    if let data = try? await photoItem.loadTransferable(type: Data.self), let safe = SafeAvatar.prepare(data) {
                        card.photo = safe
                    } else {
                        model.notice = "That photo couldn't be used. Try a JPEG or PNG."
                    }
                }
            }
        }
        .tint(theme.accent.color)
    }

    private var isBlank: Bool {
        let tidy = card.tidied()
        return [tidy.givenName, tidy.familyName, tidy.nickname, tidy.company].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && tidy.phones.isEmpty && tidy.emails.isEmpty
    }

    private var photo: some View {
        VStack(spacing: Space.s2) {
            PersonFace(photo: card.photo, name: card.name == "No name" ? "?" : card.name, diameter: Space.s8 + Space.s4)
            HStack(spacing: Space.s2) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    PhotoPickLabel(title: card.photo == nil ? "Add photo" : "Change photo")
                }
                .buttonStyle(SoftPress())
                if card.photo != nil {
                    TileButton("Remove", systemImage: "xmark") { card.photo = nil }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title)
                .font(Typeface.tileLabel)
                .foregroundStyle(Theme.current.textSecondary.color)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text).raisedField()
    }

    enum Kind { case phone, email }

    private func labelled(_ label: Binding<String>, value: Binding<String>, prompt: String, kind: Kind, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s2) {
            TextField("Label", text: label)
                .frame(width: Space.s8 + Space.s5)
                .raisedField()
            TextField(prompt, text: value)
                #if os(iOS)
                .keyboardType(kind == .phone ? .phonePad : .emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .raisedField()
            removeButton(onRemove)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(Typeface.callout.weight(.semibold))
                .foregroundStyle(Theme.current.danger.color)
                .frame(width: Space.s6 + Space.s1, height: Space.s6 + Space.s1)
                .neumorphic(.subtle, in: Circle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("Remove")
    }

    private func addLabel() {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        if !card.labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) { card.labels.append(label) }
        newLabel = ""
    }

    struct PhotoPickLabel: View {
        let title: String

        var body: some View {
            Label(title, systemImage: "photo")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.accent.color)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .neumorphic(.subtle, in: Capsule())
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var edited = card
        if hasBirthday {
            let parts = model.calendar.dateComponents([.year, .month, .day], from: birthdayDate)
            if let month = parts.month, let day = parts.day {
                edited.birthday = .init(month: month, day: day, year: knowsYear ? parts.year : nil)
            }
        } else {
            edited.birthday = nil
        }
        if let saved = await model.save(edited, over: original) { onDone(saved) }
    }
}
