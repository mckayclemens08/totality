import PhotosUI
import SwiftUI
import TotalityUI

/// A group's name and photo fields, with the plain note that neither is end-to-end encrypted.
struct GroupFields: View {
    @Binding var name: String
    /// A newly chosen photo, still as picked. Nil keeps what's there.
    @Binding var photo: Data?
    /// The photo the group already has, already opened.
    var current: Data?
    var onRemovePhoto: (() -> Void)?
    @State private var picked: PhotosPickerItem?

    var body: some View {
        let theme = Theme.current
        let shown = photo ?? current
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                PhotosPicker(selection: $picked, matching: .images) {
                    PhotoChoice(shown: shown)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(photo ?? current == nil ? "Choose a group photo" : "Change the group photo")
                TextField("Group name (optional)", text: $name)
                    .textFieldStyle(.plain)
                    .font(Typeface.body)
                    .padding(Space.s3)
                    .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .accessibilityLabel("Group name")
            }
            if let onRemovePhoto, current != nil, photo == nil {
                Button("Remove photo", role: .destructive, action: onRemovePhoto)
                    .font(Typeface.callout)
            }
            Label {
                Text("\(GroupLabels.notEncrypted) \(GroupLabels.photoOnServer)")
            } icon: {
                Image(systemName: "lock.open")
            }
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
        }
        .onChange(of: picked) {
            guard let item = picked else { return }
            Task {
                photo = try? await item.loadTransferable(type: Data.self)
                picked = nil
            }
        }
    }
}

/// A group's own small photo, or its first letter.
struct GroupAvatar: View {
    let title: String
    let location: String?
    let messages: MessagesModel?
    @State private var data: Data?

    var body: some View {
        Group {
            if let data {
                OpenedImage(data: data)
                    .scaledToFill()
                    .frame(width: Space.s7, height: Space.s7)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            } else {
                Initial(name: title)
            }
        }
        .task(id: location) {
            guard let location, let messages else { data = nil; return }
            data = await messages.groupPhoto(location)
        }
    }
}

/// Changing a group's name and photo, from its chat.
struct GroupDetailsView: View {
    let chat: ChatModel
    let messages: MessagesModel?
    let onDone: () -> Void
    @State private var name = ""
    @State private var photo: Data?
    @State private var current: Data?
    @State private var removing = false
    @State private var working = false

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.s4) {
                GroupFields(name: $name, photo: $photo, current: removing ? nil : current, onRemovePhoto: { removing = true })
                if let notice = chat.notice {
                    Text(notice).font(Typeface.caption).foregroundStyle(theme.danger.color)
                }
                Text("Everyone in the group sees a change, and that you made it.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer()
            }
            .padding(Space.s5)
            .background(theme.bg.color)
            .navigationTitle("Name and photo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else { Button("Save", action: save) }
                }
            }
        }
        .tint(theme.accent.color)
        .task {
            name = chat.title
            if let location = chat.groupPhotoLocation, let messages { current = await messages.groupPhoto(location) }
        }
    }

    private func save() {
        working = true
        Task {
            var ok = true
            if GroupName.clean(name) != GroupName.clean(chat.title) { ok = await chat.rename(name) }
            if ok, let photo { ok = await chat.setGroupPhoto(photo) }
            if ok, removing, photo == nil { ok = await chat.setGroupPhoto(nil) }
            working = false
            if ok { onDone() }
        }
    }
}

/// The round photo button: the chosen photo, or a camera mark.
private struct PhotoChoice: View {
    let shown: Data?

    var body: some View {
        let theme = Theme.current
        if let shown {
            OpenedImage(data: shown)
                .scaledToFill()
                .frame(width: Space.s7 * 1.5, height: Space.s7 * 1.5)
                .clipShape(Circle())
        } else {
            Image(systemName: "camera")
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Space.s7 * 1.5, height: Space.s7 * 1.5)
                .neumorphic(.raised, in: Circle())
        }
    }
}
