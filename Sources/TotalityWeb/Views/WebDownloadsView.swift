import SwiftUI
import TotalityUI

struct WebDownloadsView: View {
    let model: WebModel
    let onClose: () -> Void

    var body: some View {
        WebSheet(title: "Downloads", onClose: onClose) {
            if model.downloads.isEmpty {
                WebMessage(systemImage: "arrow.down.circle", title: "No downloads", detail: WebCopy.downloads)
            } else {
                ScrollView {
                    LazyVStack(spacing: Space.s3) {
                        ForEach(model.downloads) { WebDownloadRow(model: model, download: $0) }
                        Text(WebCopy.downloads)
                            .font(Typeface.caption)
                            .foregroundStyle(Theme.current.textSecondary.color)
                            .multilineTextAlignment(.center)
                            .padding(.top, Space.s3)
                    }
                    .padding(Space.s4)
                }
            }
        }
    }
}

private struct WebDownloadRow: View {
    let model: WebModel
    let download: WebDownload

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s3) {
                Image(systemName: "doc")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityHidden(true)
                Text(download.filename)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(download.state == .running ? "Cancel" : "Delete") { model.remove(download) }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textSecondary.color)
                    .buttonStyle(.plain)
            }
            switch download.state {
            case .running:
                ProgressView(value: download.progress)
                    .tint(theme.accent.color)
                    .accessibilityLabel("Downloading")
            case .failed:
                Text("This download didn't finish.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            case .finished:
                HStack(spacing: Space.s5) {
                    Button("Open in Reader") { Task { await model.openInReader(download) } }
                    ShareLink("Share", item: download.file)
                }
                .font(Typeface.callout)
                .foregroundStyle(theme.accent.color)
                .buttonStyle(.plain)
            }
        }
        .padding(Space.s4)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}
