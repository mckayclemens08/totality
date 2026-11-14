import SwiftUI
import TotalityCore
import TotalityUI

/// A folder in Google Drive, linked or inside a linked one.
struct DriveLocation: Hashable {
    let account: String
    let folderID: String
    let name: String
}

extension DriveEntry {
    /// What the Reader calls this kind of file.
    var typeName: String {
        switch mime {
        case DriveEntry.folderMime: "Folder"
        case DriveEntry.googleDocMime: "Google Doc"
        case "application/vnd.google-apps.spreadsheet": "Google Sheet"
        case "application/vnd.google-apps.presentation": "Google Slides"
        case "application/pdf": "PDF"
        case ReadableText.epubMime: "EPUB"
        case ReadableText.wordMime: "Word"
        case "text/markdown", "text/x-markdown": "Markdown"
        case _ where mime.hasPrefix("text/"): "Text"
        case _ where mime.hasPrefix("image/"): "Image"
        default: "File"
        }
    }

    var systemImage: String {
        switch typeName {
        case "Folder": "folder"
        case "Google Doc", "Markdown", "Text": "doc.text"
        case "PDF": "doc.richtext"
        case "EPUB": "book.closed"
        case "Word": "doc.plaintext"
        case "Image": "photo"
        case "Google Sheet": "tablecells"
        case "Google Slides": "rectangle.on.rectangle"
        default: "doc"
        }
    }

    /// The quiet line under a name: kind, size, and when it last changed in Drive.
    var detail: String {
        var parts = [typeName]
        if let size, !isFolder { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let modifiedAt { parts.append(modifiedAt.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}

/// One Drive folder's contents, as kept on the device, brought up to date from Google as it opens.
struct DriveFolderView: View {
    let location: DriveLocation
    let drive: DriveModel

    private var theme: Theme { .current }
    private var listing: DriveListing? { drive.listing(location.folderID, account: location.account) }
    private var problem: DriveProblem? { drive.problem(location.folderID, account: location.account) }

    var body: some View {
        content
            .background(theme.bg.color)
            .navigationTitle(location.name)
            .refreshable { await drive.refresh(location.folderID, account: location.account) }
            .task { await drive.open(location.folderID, account: location.account) }
    }

    @ViewBuilder private var content: some View {
        if let listing {
            List {
                header
                if let problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.danger.color)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if listing.entries.isEmpty {
                    Text("This folder is empty in Google Drive.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(listing.entries) { entry in
                    row(entry)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else if let problem {
            ReaderMessage(systemImage: "exclamationmark.icloud", title: "This folder didn't open", detail: problem.message)
        } else {
            ProgressView("Reading from Google Drive")
                .font(Typeface.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        Label("\(DriveModel.label). \(location.account)", systemImage: "lock.open")
            .font(Typeface.caption)
            .foregroundStyle(theme.textSecondary.color)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder private func row(_ entry: DriveEntry) -> some View {
        if entry.isFolder {
            NavigationLink(value: ReaderRoute.drive(DriveLocation(account: location.account, folderID: entry.id, name: entry.name))) {
                DriveEntryRow(entry: entry)
            }
        } else {
            NavigationLink(value: ReaderRoute.driveFile(DriveFileRoute(location: location, entry: entry))) {
                DriveEntryRow(entry: entry)
            }
        }
    }
}

struct DriveEntryRow: View {
    let entry: DriveEntry

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(entry.isFolder ? theme.accent.color : theme.textSecondary.color)
                .frame(width: Space.s5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(entry.name)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                Text(entry.detail)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s1)
        .accessibilityElement(children: .combine)
    }
}

/// The linked folders, at the top of the Reader.
struct DriveLinksSection: View {
    let drive: DriveModel

    var body: some View {
        let theme = Theme.current
        ForEach(drive.links) { link in
            NavigationLink(value: ReaderRoute.drive(DriveLocation(account: link.account, folderID: link.folderID, name: link.name))) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    DriveLinkRow(link: link)
                    if let problem = drive.problem(link.folderID, account: link.account), !problem.isPassing {
                        Text(problem.message)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                    } else if drive.needsAllowing.contains(link.account) {
                        Text(DriveProblem.notAllowed.message)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}
