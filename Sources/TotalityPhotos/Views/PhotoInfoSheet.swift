import SwiftUI
import TotalityCore
import TotalityUI

/// A photo's caption and what it says about itself. The camera and place are read from the sealed
/// original on this device. The place is shown as coordinates and never looked up, which would send it
/// to a server.
struct PhotoInfoSheet: View {
    let model: PhotosModel
    let item: PhotoItem
    @State private var caption = ""
    @State private var info: PhotoImport.Info?
    @State private var isReading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = Theme.current
        let details = (model.current(item) ?? item).details
        NavigationStack {
            Form {
                Section("Caption") {
                    TextField("Add a caption", text: $caption, axis: .vertical)
                        .lineLimit(1...5)
                        .raisedField()
                }
                Section("Details") {
                    row("Taken", details.taken?.formatted(date: .long, time: .shortened) ?? "Not in the file")
                    row("Added", details.added.formatted(date: .long, time: .shortened))
                    row("Size", "\(details.width) × \(details.height), \(details.byteCount.formatted(ByteCountFormatStyle(style: .file)))")
                    if isReading {
                        HStack { Text("Camera and place"); Spacer(); ProgressView() }
                    } else {
                        row("Camera", info?.camera ?? "Not in the file")
                        if let lens = info?.lens { row("Lens", lens) }
                        row("Place", info?.place ?? "Not in the file")
                    }
                }
                Section {
                    Text("The caption and everything here are sealed with the photo. The server can't read them.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .navigationTitle("Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let text = caption
                        Task { await model.setCaption(item, to: text) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(theme.accent.color)
        .onAppear { caption = details.caption ?? "" }
        .task {
            info = await model.info(item)
            isReading = false
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: Space.s4)
            Text(value).foregroundStyle(Theme.current.textSecondary.color).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
