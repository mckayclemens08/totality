import AuthenticationServices
import SwiftUI
import TotalityCore
import TotalityUI

/// Add from Google Photos: choose the Google account, pick in Google Photos, and come back. It says
/// first what Google gives and what it doesn't.
struct GoogleImportSheet: View {
    let model: PhotosModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var albumName = ""
    @State private var connections: [GoogleConnection] = []

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            Form {
                switch model.googleState {
                case .idle, .problem:
                    if case .problem(let message) = model.googleState {
                        Section { Text(message).foregroundStyle(theme.danger.color) }
                    }
                    if model.isGoogleBusy {
                        Section { ProgressView("Stopping…") }
                    }
                    Section {
                        TextField("Put them in an album (optional)", text: $albumName)
                            .raisedField()
                    } footer: {
                        Text("Google doesn't say which album something came from, so name one here to keep them together.")
                            .font(Typeface.caption)
                    }
                    Section {
                        ForEach(connections, id: \.address) { connection in
                            Button("Choose with \(connection.address)") { start(connection.address) }
                                .disabled(model.isGoogleBusy)
                        }
                        Button(connections.isEmpty ? "Choose in Google Photos" : "Use Another Google Account") { start(nil) }
                            .disabled(model.isGoogleBusy)
                    } footer: {
                        Text("You pick photos, videos or albums in Google Photos, up to 2,000 at a time. They come from Google straight to this device and are sealed here before they upload. Google removes where photos were taken, and videos come as Google's re-encoded copy. Your Google Photos library isn't changed, and Totality keeps nothing else from Google.")
                            .font(Typeface.caption)
                    }
                case .connecting:
                    Section { ProgressView("Connecting to Google…") }
                case .picking:
                    Section {
                        Text("Pick in Google Photos, then come back here. Totality waits for you.")
                        Button("Stop", role: .destructive) { model.stopGoogleImport() }
                    }
                case .bringing(let done, let total):
                    Section {
                        if total > 0 {
                            ProgressView(value: Double(done), total: Double(total)) { Text("Bringing in \(done) of \(total)") }
                        } else {
                            ProgressView("Getting what you picked…")
                        }
                        Button("Stop", role: .destructive) { model.stopGoogleImport() }
                    } footer: {
                        Text("What's already in stays if you stop, and is skipped if you pick it again.").font(Typeface.caption)
                    }
                case .finished(let report):
                    Section { Text(PhotosModel.googleSummary(report)) }
                }
            }
            .navigationTitle("Google Photos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.clearGoogleImport()
                        dismiss()
                    }
                }
            }
            .task { connections = model.googleConnections() }
        }
    }

    private func start(_ account: String?) {
        let session = webAuthenticationSession
        let open = openURL
        let name = albumName
        Task {
            await model.importFromGoogle(account: account, albumName: name.isEmpty ? nil : name, signIn: { page, scheme in
                try await session.authenticate(using: page, callbackURLScheme: scheme, preferredBrowserSession: .shared)
            }, open: { open($0) })
            connections = model.googleConnections()
        }
    }
}
