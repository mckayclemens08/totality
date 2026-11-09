import SwiftUI
import TotalityCore
import TotalityUI

/// Sharing a photo or an album with someone by username. Nothing goes until Send is pressed, and the
/// sheet says first what the other person gets and what stopping can't undo.
struct ShareSheet: View {
    let model: PhotosModel
    let items: [PhotoItem]
    /// Set when a whole album is shared, which goes as a snapshot under its name.
    let albumName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var problem: String?
    @State private var finished = false

    var body: some View {
        let theme = Theme.current
        let plan = model.sharePlan(items)
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .disabled(model.sharing != nil || finished)
                } header: {
                    Text(title(plan))
                } footer: {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("They get a copy in your end-to-end encrypted one-to-one chat with them in Messages. Photos are sent at up to 2048 pixels, and where, when and on what they were taken is removed first.")
                        Text("Deleting the message in the chat stops it opening again, but can't take back a copy they've already seen or saved.")
                        if plan.tooLong > 0 { Text(PhotosModel.tooLongNotice(model.sender?.longestVideo ?? 0)) }
                        if plan.overLimit > 0 { Text("Only the first \(PhotosModel.shareLimit) will be sent.") }
                    }
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                }
                if let sharing = model.sharing {
                    Section {
                        ProgressView(value: Double(sharing.done), total: Double(max(sharing.total, 1))) {
                            Text("Sending \(sharing.done) of \(sharing.total)")
                        }
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(theme.danger.color) }
                } else if finished {
                    Section { Text("Sent. It's in your chat with \(username) in Messages.").foregroundStyle(theme.textPrimary.color) }
                }
            }
            .navigationTitle(albumName == nil ? "Share" : "Share Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Cancel") { dismiss() }.disabled(model.sharing != nil)
                }
                if !finished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { send() }
                            .disabled(plan.items.isEmpty || model.sharing != nil || username.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.sharing != nil)
    }

    private func title(_ plan: PhotosModel.SharePlan) -> String {
        let count = plan.items.count
        let what = count == 1 ? (plan.items.first?.details.isVideo == true ? "1 video" : "1 photo") : "\(count) items"
        if let albumName { return "\(albumName): \(what)" }
        return what
    }

    private func send() {
        let name = username.trimmingCharacters(in: .whitespaces)
        problem = nil
        Task {
            let result = await model.share(items, albumName: albumName, to: name)
            problem = result
            // Something went, even if not everything, so Send isn't offered again to send it twice.
            finished = result == nil || model.lastShareSent > 0
        }
    }
}
