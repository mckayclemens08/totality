import AuthenticationServices
import SwiftUI
import TotalityCore
import TotalityUI

/// Reader, Add, Google Drive: pick a Google account, allow Drive with one tap, and tick the folders to
/// link. It says first what Google holds and what Totality never sees.
struct DriveLinkSheet: View {
    let model: DriveModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var path: [DriveRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            DriveAccountsPage(model: model, path: $path, signIn: signIn)
                .navigationDestination(for: DriveRoute.self) { route in
                    DriveChooserPage(model: model, account: route.account, place: route.place, path: $path)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(Theme.current.accent.color)
        .task { await model.load() }
    }

    private var signIn: DriveModel.SignIn {
        let session = webAuthenticationSession
        return { page, scheme in
            try await session.authenticate(using: page, callbackURLScheme: scheme, preferredBrowserSession: .shared)
        }
    }
}

struct DriveRoute: Hashable {
    let account: String
    let place: DrivePlace
}

/// The first page: what's linked already, and the Google accounts to choose folders from.
private struct DriveAccountsPage: View {
    let model: DriveModel
    @Binding var path: [DriveRoute]
    let signIn: DriveModel.SignIn

    var body: some View {
        let theme = Theme.current
        Form {
            if let problem = model.problem {
                Section { Text(problem).foregroundStyle(theme.danger.color) }
            }
            if !model.links.isEmpty {
                Section {
                    ForEach(model.links) { link in
                        DriveLinkRow(link: link)
                            .swipeActions {
                                Button("Unlink", systemImage: "link.badge.minus", role: .destructive) {
                                    Task { await model.unlink(link) }
                                }
                            }
                            .contextMenu {
                                Button("Unlink", systemImage: "link.badge.minus", role: .destructive) {
                                    Task { await model.unlink(link) }
                                }
                            }
                    }
                } header: {
                    Text("Linked folders")
                } footer: {
                    Text("Unlinking only removes a folder from the Reader. Nothing in Google Drive changes.")
                        .font(Typeface.caption)
                }
            }
            Section {
                if model.isConnecting {
                    ProgressView("Connecting to Google…")
                } else {
                    ForEach(model.accounts) { account in
                        Button {
                            choose(account.address)
                        } label: {
                            VStack(alignment: .leading, spacing: Space.s1) {
                                Text("Choose from \(account.address)")
                                if !account.allowsDrive {
                                    Text("Google asks once to allow Drive.")
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textSecondary.color)
                                }
                            }
                        }
                    }
                    Button(model.accounts.isEmpty ? "Connect Google Drive" : "Use Another Google Account") { choose(nil) }
                }
            } header: {
                Text("Link folders")
            } footer: {
                Label(DriveModel.explanation, systemImage: "lock.open")
                    .font(Typeface.caption)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .navigationTitle("Google Drive")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func choose(_ account: String?) {
        Task {
            if let address = await model.connect(account, signIn: signIn) {
                path = [DriveRoute(account: address, place: .myDrive)]
            }
        }
    }
}

/// A linked folder, with the honest label under its name.
struct DriveLinkRow: View {
    let link: DriveLink

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            DriveMark()
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(link.name)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                Text("\(link.account) · \(DriveModel.label)")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The mark that tells a Drive folder from one of the Reader's own: a folder with a cloud.
struct DriveMark: View {
    var body: some View {
        Image(systemName: "folder")
            .foregroundStyle(Theme.current.accent.color)
            .frame(width: Space.s5)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "icloud.fill")
                    .font(Typeface.micro)
                    .foregroundStyle(Theme.current.textSecondary.color)
                    .offset(x: Space.s1, y: Space.s1)
            }
            .accessibilityLabel("Google Drive folder")
    }
}

/// One place in the person's Drive: its folders, each with a Link button and a way inside.
private struct DriveChooserPage: View {
    let model: DriveModel
    let account: String
    let place: DrivePlace
    @Binding var path: [DriveRoute]

    private enum Phase: Equatable {
        case loading
        case ready([DriveEntry])
        case failed(String)
    }

    @State private var phase = Phase.loading

    var body: some View {
        let theme = Theme.current
        List {
            if place == .myDrive {
                Section {
                    NavigationLink(value: DriveRoute(account: account, place: .sharedWithMe)) {
                        Label("Shared with me", systemImage: "person.2")
                    }
                } footer: {
                    Text("Signed in as \(account)").font(Typeface.caption)
                }
            }
            Section(place == .myDrive ? "My Drive" : "Folders") {
                switch phase {
                case .loading:
                    ProgressView("Reading your Drive…")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(message).foregroundStyle(theme.danger.color)
                        Button("Try Again") { Task { await read() } }
                    }
                case .ready(let folders) where folders.isEmpty:
                    Text(place == .sharedWithMe ? "No one has shared a folder with this account." : "There are no folders here.")
                        .foregroundStyle(theme.textSecondary.color)
                case .ready(let folders):
                    ForEach(folders) { folder in
                        row(folder)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg.color)
        .navigationTitle(place.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await read() }
        .task { await read() }
    }

    private func row(_ folder: DriveEntry) -> some View {
        let isLinked = model.isLinked(folder, account: account)
        return HStack(spacing: Space.s3) {
            Button {
                path.append(DriveRoute(account: account, place: .folder(id: folder.id, name: folder.name)))
            } label: {
                Label(folder.name, systemImage: "folder")
                    .foregroundStyle(Theme.current.textPrimary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the folders inside")
            Button(isLinked ? "Linked" : "Link", systemImage: isLinked ? "checkmark.circle.fill" : "plus.circle") {
                Task { await model.setLinked(!isLinked, folder: folder, account: account) }
            }
            .labelStyle(.iconOnly)
            .font(Typeface.title)
            .buttonStyle(.borderless)
            .accessibilityLabel(isLinked ? "Unlink \(folder.name)" : "Link \(folder.name)")
        }
    }

    private func read() async {
        if case .ready = phase {} else { phase = .loading }
        do {
            phase = .ready(try await model.folders(in: place, account: account))
        } catch is CancellationError {
        } catch {
            phase = .failed(DriveProblem.from(error).message)
        }
    }
}
