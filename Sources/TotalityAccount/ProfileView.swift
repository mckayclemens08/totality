import PhotosUI
import SwiftUI
import TotalityCore
import TotalityUI

/// The signed-in page: who you are to other people, and the way to change it.
struct ProfileSummary: View {
    let model: AccountModel
    let onEdit: () -> Void
    let onShare: () -> Void

    var body: some View {
        if let profile = model.profile {
            ProfileHeader(profile: profile)
            // Every account's username is also its mail address, for good.
            AddressLine("Your email address", address: MailDomain.address(for: profile.username))
                .padding(Space.s4)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
            HStack(spacing: Space.s3) {
                AccountButton(title: "Edit profile", isWorking: false, action: onEdit)
                AccountButton(title: "Share profile", isWorking: false, action: onShare)
            }
        } else if model.profileFailed {
            AccountDetail(text: "Your profile didn't load.")
            Button("Try again") { Task { await model.loadProfile() } }
                .font(Typeface.callout)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }
}

struct ProfileHeader: View {
    let profile: Profile

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            ProfilePicture(url: profile.avatarURL)
                .padding(.bottom, Space.s2)
            Text(profile.displayName ?? "@\(profile.username)")
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            if profile.displayName != nil {
                Text("@\(profile.username)")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
            }
            if let bio = profile.bio {
                Text(bio)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .padding(.top, Space.s2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

struct ProfilePicture: View {
    private static let diameter = Space.s8 * 1.5

    let url: URL?

    var body: some View {
        let theme = Theme.current
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        placeholder
                    } else {
                        ProgressView()
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .clipShape(Circle())
        .neumorphic(.raised, in: Circle())
        .foregroundStyle(theme.textSecondary.color)
        .accessibilityLabel("Profile photo")
    }

    private var placeholder: some View {
        Image(systemName: "person.fill")
            .font(Typeface.display)
    }
}

/// Photo changes save straight away, like they do on other apps. The name and bio wait for Save.
struct EditProfileView: View {
    let model: AccountModel
    let onDone: () -> Void
    @State private var displayName: String
    @State private var bio: String
    @State private var picked: PhotosPickerItem?

    init(model: AccountModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        _displayName = State(initialValue: model.profile?.displayName ?? "")
        _bio = State(initialValue: model.profile?.bio ?? "")
    }

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                VStack(spacing: Space.s3) {
                    ProfilePicture(url: model.profile?.avatarURL)
                    PhotosPicker(model.profile?.avatarURL == nil ? "Add photo" : "Change photo", selection: $picked, matching: .images)
                        .font(Typeface.callout)
                    if model.profile?.avatarURL != nil {
                        Button("Remove photo") { Task { await model.removePhoto() } }
                            .font(Typeface.callout)
                            .foregroundStyle(theme.danger.color)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent.color)
                .disabled(model.isWorking)
                .frame(maxWidth: .infinity)

                TextField("Name", text: $displayName)
                    .modifier(ProfileField())
                TextField("Bio", text: $bio, axis: .vertical)
                    .lineLimit(3...5)
                    .modifier(ProfileField())
                Text("\(bio.count) of \(Profile.maximumBioLength)")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                AccountDetail(text: "Your name, photo, and bio are public and aren't encrypted.")
                AccountButton(title: "Save", isWorking: model.isWorking) {
                    Task {
                        if await model.saveProfile(displayName: displayName, bio: bio) { onDone() }
                    }
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.danger.color)
                }
            }
            .padding(Space.s4)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.bg.color)
        .navigationTitle("Edit profile")
        .onAppear { model.notice = nil }
        .onChange(of: picked) {
            guard let picked else { return }
            Task {
                if let picture = try? await picked.loadTransferable(type: Data.self) {
                    await model.setPhoto(picture)
                } else {
                    model.notice = "That picture can't be used. Try another."
                }
                self.picked = nil
            }
        }
    }
}

private struct ProfileField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typeface.body)
            .textFieldStyle(.plain)
            .padding(Space.s4)
            .neumorphic(.pressed, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

/// Which home page Totality opens on. It's on this device and needs no account.
struct HomeStyleSetting: View {
    @AppStorage(HomeStyle.defaultKey) private var defaultHome = HomeStyle.tiles

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Home page")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textPrimary.color)
            Picker("Home page", selection: $defaultHome) {
                ForEach(HomeStyle.allCases) { style in
                    Text(style.name).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

struct AccountSettingsView: View {
    let model: AccountModel

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s4) {
            HomeStyleSetting()
            if case .signedIn(let username) = model.phase {
                AccountDetail(text: "Signed in as \(username).")
            }
            AccountDetail(text: model.deviceRegistered ? "This device is added to your account." : "This device isn't added to your account yet.")
            AccountDetail(text: model.sync?.isAvailable == true
                ? "Your notes, files, and events sync between your devices, encrypted. Signing out leaves them on this device, and event reminders keep showing."
                : "Set up your recovery key to sync your notes, files, and events. Signing out leaves them on this device, and event reminders keep showing.")
            if let sync = model.sync, let summary = sync.summary {
                AccountDetail(text: summary)
                Button("Sync now") { Task { await sync.syncNow() } }
                    .font(Typeface.callout)
                    .disabled(sync.status == .syncing)
                if sync.heldRemovals > 0 {
                    Button("Remove those \(sync.heldRemovals) items here too") { Task { await sync.applyHeldRemovals() } }
                        .font(Typeface.callout)
                        .disabled(sync.status == .syncing)
                }
            }
            if let backup = model.backup {
                NavigationLink("Recovery key") { BackupView(model: backup) }
                    .font(Typeface.callout)
            }
            AccountButton(title: "Sign out", isWorking: model.isWorking) { Task { await model.signOut() } }
            if let notice = model.notice {
                Text(notice)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.danger.color)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg.color)
        .navigationTitle("Settings")
    }
}

struct AccountDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.body)
            .foregroundStyle(Theme.current.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AccountButton: View {
    let title: String
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().tint(theme.accentOn.color)
                } else {
                    Text(title)
                }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.accentOn.color)
            .frame(maxWidth: .infinity)
            .padding(Space.s4)
            .background(theme.accent.color, in: RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}
