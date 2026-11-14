import SwiftUI
import TotalityCore
import TotalityUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A file in a linked Drive folder, as the Reader opens it.
struct DriveFileRoute: Hashable {
    let location: DriveLocation
    let entry: DriveEntry
}

/// Opens a Drive file in the Reader's own viewers, from the sealed copy on the device or straight from
/// Google. PDFs, EPUBs, Word files, text and Markdown open as they do in the Reader, Listen included;
/// Google Docs come as Markdown, and Sheets and Slides as PDF. It's read-only for now.
struct DriveFileView: View {
    let route: DriveFileRoute
    let model: ReaderModel

    private enum Phase {
        case loading
        case ready(ReaderItem, Data)
        case failed(String)
    }

    @State private var phase = Phase.loading

    var body: some View {
        let theme = Theme.current
        Group {
            switch phase {
            case .loading:
                ProgressView(route.entry.size.map { $0 > 2_000_000 } == true ? "Downloading from Google Drive" : "Opening")
                    .font(Typeface.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ReaderMessage(systemImage: "exclamationmark.icloud", title: "This file didn't open", detail: message)
            case .ready(let item, let data):
                if item.mime?.hasPrefix("image/") == true {
                    DriveImage(data: data)
                        .navigationTitle(item.displayTitle)
                } else {
                    ReaderItemView(item: item, model: model)
                }
            }
        }
        .background(theme.bg.color)
        .safeAreaInset(edge: .top, spacing: 0) {
            Label(DriveModel.label, systemImage: "lock.open")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s1)
                .background(theme.bg.color)
        }
        .task(id: route) { await open() }
    }

    private func open() async {
        guard let drive = model.drive else {
            phase = .failed(DriveProblem.notSetUp.message)
            return
        }
        do {
            let opened = try await drive.openFile(route.entry, in: route.location.folderID, account: route.location.account)
            phase = .ready(opened.item, opened.file.data)
        } catch is CancellationError {
        } catch let error as ReaderError {
            phase = .failed(error == .notReadable ? "The Reader can't show this kind of file yet. It's still in Google Drive." : error.message)
        } catch {
            phase = .failed(DriveProblem.from(error).message)
        }
    }
}

/// A picture from Drive, fitted to the screen.
private struct DriveImage: View {
    let data: Data

    var body: some View {
        if let image {
            ScrollView([.horizontal, .vertical]) {
                image
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
        } else {
            ReaderMessage(systemImage: "photo", title: "This picture didn't open", detail: "It may be damaged, or in a format this device can't show.")
        }
    }

    private var image: Image? {
        #if canImport(UIKit)
        UIImage(data: data).map { Image(uiImage: $0) }
        #else
        NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }
}
