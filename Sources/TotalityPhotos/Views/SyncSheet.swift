#if os(iOS)
import Photos
import PhotosUI
import SwiftUI
import TotalityUI
import UIKit

/// Sync this iPhone: off until turned on, and turning it on is the first time Totality reads the
/// device's library, so the sheet says so before iOS asks.
struct SyncSheet: View {
    let model: PhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var access = PhotoKitSource.access
    @State private var months: [(id: String, count: Int)] = []
    @State private var pending: Int?

    var body: some View {
        let theme = Theme.current
        let record = model.syncRecord ?? SyncRecord()
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync this iPhone", isOn: Binding(get: { record.isOn }, set: { on in Task { await turn(on) } }))
                        .disabled(access == .refused && !record.isOn)
                } footer: {
                    Text(record.isOn
                        ? "New photos and Live Photos on this iPhone come into Totality, sealed on the iPhone before they upload. Deleting one here or there never deletes it on the other side, and edits made on the iPhone later don't sync."
                        : "Turning this on lets Totality read this iPhone's photo library for the first time, to bring in new photos from today on. Each is sealed on the iPhone before it uploads, so the server can't see it. iOS asks first, and you can give access to only some photos.")
                        .font(Typeface.caption)
                }
                if access == .refused {
                    Section {
                        Text("Totality doesn't have access to your photo library.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } else if access == .limited, record.isOn {
                    Section {
                        Text("You gave access to some photos only, so only those sync.")
                        Button("Choose Photos") { chooseMore() }
                    }
                }
                if record.isOn {
                    Section {
                        if let line = model.syncLine { Text(line) }
                        if let usage = model.usageLine { Text(usage).foregroundStyle(theme.textSecondary.color) }
                        Button(model.isSyncing ? "Syncing…" : "Sync Now") { Task { await model.runSync() } }
                            .disabled(model.isSyncing)
                    }
                    Section {
                        Toggle("Videos", isOn: Binding(get: { record.videos }, set: { on in Task { await model.setSyncVideos(on) } }))
                        Toggle("Use Mobile Data", isOn: Binding(get: { record.mobileData }, set: { on in Task { await model.setSyncMobileData(on) } }))
                    } footer: {
                        Text("Videos are most of a library's size, so they're off at first. Without mobile data, sync waits for Wi-Fi, and photos kept only in iCloud always wait for Wi-Fi.")
                            .font(Typeface.caption)
                    }
                    Section {
                        ForEach(months, id: \.id) { month in
                            Toggle(isOn: Binding(
                                get: { record.months.contains(month.id) },
                                set: { on in Task { await model.setSyncMonth(month.id, included: on) } }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(Self.title(of: month.id))
                                    Text(month.count == 1 ? "1 item" : "\(month.count.formatted()) items")
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textSecondary.color)
                                }
                            }
                        }
                    } header: {
                        Text("Earlier photos")
                    } footer: {
                        Text("Your space is \(model.usage.map { $0.limit.formatted(ByteCountFormatStyle(style: .file)) } ?? "limited"). Choose the months you want backed up, newest first. When it's full, sync stops and says so, and nothing is lost on the iPhone.")
                            .font(Typeface.caption)
                    }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: record.isOn) {
                access = PhotoKitSource.access
                if record.isOn { months = await model.syncMonths() }
            }
        }
    }

    private func turn(_ on: Bool) async {
        if on, access == .notAsked { access = await PhotoKitSource.ask() }
        guard !on || access == .full || access == .limited else { return }
        await model.setSync(on: on)
    }

    private func chooseMore() {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        var top = root
        while let shown = top.presentedViewController { top = shown }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in
            Task { @MainActor in
                months = await model.syncMonths()
                await model.runSync()
            }
        }
    }

    static func title(of month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1])) else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }
}
#endif
