import SwiftUI
import TotalityCore
import TotalityUI

/// The public profile: who you are to other people, and the way to change it. Reached from the Account page.
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
            ProfileLinkChips(stored: profile.links)
                .padding(.top, Space.s2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

struct ProfilePicture: View {
    let url: URL?
    var diameter = Space.s8 * 1.5

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
        .frame(width: diameter, height: diameter)
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
    @State private var links: [String]
    @State private var choosingPhoto = false

    init(model: AccountModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        _displayName = State(initialValue: model.profile?.displayName ?? "")
        _bio = State(initialValue: model.profile?.bio ?? "")
        _links = State(initialValue: model.profile?.links ?? [])
    }

    /// One box per link, with a way to remove it, and an add button until there are five.
    @ViewBuilder
    private func linkFields(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Links").font(Typeface.callout).foregroundStyle(theme.textSecondary.color)
            ForEach(links.indices, id: \.self) { index in
                HStack(spacing: Space.s2) {
                    TextField("example.com", text: $links[index])
                        .modifier(LinkEntry())
                        .modifier(ProfileField())
                    Button { links.remove(at: index) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textSecondary.color)
                            .frame(minWidth: Space.s7, minHeight: Space.s7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove link")
                }
            }
            if links.count < ProfileLinks.maximumCount {
                Button { links.append("") } label: {
                    Label("Add a link", systemImage: "plus").font(Typeface.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent.color)
                .frame(minHeight: Space.s7, alignment: .leading)
            }
        }
    }

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                VStack(spacing: Space.s3) {
                    ProfilePicture(url: model.profile?.avatarURL)
                    Button(model.profile?.avatarURL == nil ? "Add photo" : "Change photo") { choosingPhoto = true }
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
                linkFields(theme)
                AccountDetail(text: "Your name, photo, bio, and links are public and aren't encrypted.")
                AccountButton(title: "Save", isWorking: model.isWorking) {
                    Task {
                        if await model.saveProfile(displayName: displayName, bio: bio, links: links) { onDone() }
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
        .photoChooser(isPresented: $choosingPhoto) { media in
            if case .photo(let picture, _)? = media.first {
                await model.setPhoto(picture)
            } else {
                model.notice = "That picture can't be used. Try another."
            }
        }
    }
}

/// Web-address keyboard, no capital letters, no autocorrect.
private struct LinkEntry: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        content.autocorrectionDisabled()
        #endif
    }
}

private struct ProfileField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Typeface.body)
            .raisedField()
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
