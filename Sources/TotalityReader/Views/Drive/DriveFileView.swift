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
/// Google Docs come as Markdown, and Sheets and Slides as PDF. Text and Markdown can be edited and saved
/// back to Drive. Word files and Google Docs are read-only, and Import makes a Totality doc to edit.
struct DriveFileView: View {
    let route: DriveFileRoute
    let model: ReaderModel

    private enum Phase {
        case loading
        case ready(ReaderItem, DriveOpenedFile)
        case failed(String)
    }

    @State private var phase = Phase.loading
    @State private var editing = false
    @State private var importing = false
    @State private var notice: String?

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
            case .ready(let item, let file):
                if item.mime?.hasPrefix("image/") == true {
                    DriveImage(data: file.data)
                        .navigationTitle(item.displayTitle)
                } else {
                    ReaderItemView(item: item, model: model)
                        // A saved change is a new version, so the viewer reads it again.
                        .id(file.version ?? "")
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
        .toolbar {
            if case .ready(_, let file) = phase {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if file.entry.isEditableText {
                            Button("Edit", systemImage: "pencil") { editing = true }
                        }
                        Button(importing ? "Importing…" : "Import to Reader", systemImage: "square.and.arrow.down") {
                            Task { await importToReader(file) }
                        }
                        .disabled(importing)
                    } label: {
                        ToolbarGlyph(systemImage: "ellipsis").accessibilityLabel("Drive file actions")
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if case .ready(_, let file) = phase, let drive = model.drive {
                DriveTextEditor(file: file, drive: drive) { saved in
                    Task { await show(saved) }
                }
            }
        }
        .alert("Google Drive", isPresented: noticeShown) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .task(id: route) { await open() }
        .onChange(of: model.drive?.fileUpdates[GoogleDrive.key(route.location.account, route.entry.id)]) {
            // A newer version came in the background. The open editor keeps what's being typed.
            guard !editing else { return }
            Task { await open() }
        }
        .onChange(of: model.drive?.openedGeneration) {
            // Whoever's here changed, or the folder was unlinked: what this showed goes too.
            editing = false
            phase = .failed("This file was closed. Open it again from its folder.")
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private func open() async {
        guard let drive = model.drive else {
            phase = .failed(DriveProblem.notSetUp.message)
            return
        }
        do {
            let opened = try await drive.openFile(route.entry, in: route.location.folderID, account: route.location.account)
            phase = .ready(opened.item, opened.file)
        } catch is CancellationError {
        } catch let error as ReaderError {
            phase = .failed(error == .notReadable ? "The Reader can't show this kind of file yet. It's still in Google Drive." : error.message)
        } catch {
            phase = .failed(DriveProblem.from(error).message)
        }
    }

    private func show(_ saved: DriveOpenedFile) async {
        guard let drive = model.drive, let item = try? await drive.hold(saved) else { return }
        phase = .ready(item, saved)
    }

    private func importToReader(_ file: DriveOpenedFile) async {
        guard let drive = model.drive else { return }
        importing = true
        defer { importing = false }
        do {
            let item = try await drive.importToReader(file)
            await model.load()
            notice = "\(item.displayTitle) is now in your Reader, encrypted, and uses your Totality storage. The original stays in Google Drive."
        } catch let error as ReaderError {
            notice = error == .tooLarge ? "Files up to 5 GB can be imported. This one stays in Google Drive." : error.message
        } catch {
            notice = "This couldn't be imported. Try again."
        }
    }
}

/// Changes a Drive text or Markdown file in the writing editor, and saves it back as a new Drive revision.
/// If Drive's copy changed meanwhile, it stops and asks: keep both, or use this version.
private struct DriveTextEditor: View {
    let file: DriveOpenedFile
    let drive: DriveModel
    let onSaved: (DriveOpenedFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editor = WritingEditorController()
    @State private var loadedRevision: Int?
    @State private var isSaving = false
    @State private var conflict = false
    @State private var failure: String?

    private var hasChanges: Bool {
        loadedRevision.map { editor.revision != $0 } ?? false
    }

    var body: some View {
        NavigationStack {
            page
                .toolbar { toolbar }
                .confirmationDialog("This file changed in Google Drive", isPresented: $conflict, titleVisibility: .visible) {
                    Button("Keep Both") { Task { await keepBoth() } }
                    Button("Use Mine", role: .destructive) { Task { await save(overwrite: true) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Someone changed it after you opened it. Keep Both saves your version as a new file beside it. Use Mine replaces Drive's version with yours, and Drive keeps the old one in its version history.")
                }
                .alert("Not saved", isPresented: failureShown) {
                    Button("OK", role: .cancel) { failure = nil }
                } message: {
                    Text(failure ?? "")
                }
        }
        .tint(Theme.current.accent.color)
        .interactiveDismissDisabled(hasChanges)
        .task {
            await editor.start()
            editor.load(String(decoding: file.data, as: UTF8.self))
            loadedRevision = editor.revision
        }
    }

    private var page: some View {
        let theme = Theme.current
        return Group {
                if case .failed(let reason) = editor.phase {
                    ReaderMessage(systemImage: "exclamationmark.triangle", title: "The editor didn't open", detail: reason)
                } else {
                    WritingEditorView(controller: editor, webView: editor.webView)
                        .overlay {
                            if editor.phase == .starting { ProgressView() }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg.color)
            .safeAreaInset(edge: .top, spacing: 0) {
                Label("Saves to Google Drive as a new version. \(DriveModel.label).", systemImage: "lock.open")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s1)
            }
            .navigationTitle(file.entry.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView()
            } else {
                Button("Save") { Task { await save(overwrite: false) } }
                    .disabled(!hasChanges)
            }
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private func save(overwrite: Bool) async {
        isSaving = true
        defer { isSaving = false }
        await editor.flush()
        switch await drive.save(editor.text, over: file, overwrite: overwrite) {
        case .saved(let saved):
            onSaved(saved)
            dismiss()
        case .changedInDrive:
            conflict = true
        case .failed(let message):
            failure = message
        }
    }

    private func keepBoth() async {
        isSaving = true
        defer { isSaving = false }
        await editor.flush()
        if await drive.saveCopy(editor.text, of: file) != nil {
            dismiss()
        } else {
            failure = drive.problem ?? "Your copy wasn't saved to Google Drive."
            drive.problem = nil
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
