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
        .onAppear(perform: model.downloadsSeen)
        .onDisappear(perform: model.downloadsSeen)
    }
}

/// Safari's marker: a ring that fills while a file comes in, then a solid arrow until it's been looked at.
struct WebDownloadStatus: View {
    /// Nil when nothing is running.
    let progress: Double?

    var body: some View {
        let theme = Theme.current
        Group {
            if let progress {
                ZStack {
                    Circle()
                        .stroke(theme.textSecondary.color.opacity(0.35), lineWidth: Space.hairline * 2)
                    Circle()
                        .trim(from: 0, to: max(progress, 0.04))
                        .stroke(theme.accent.color, style: StrokeStyle(lineWidth: Space.hairline * 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.accent.color)
                }
                .frame(width: Space.s5, height: Space.s5)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(Typeface.title)
                    .foregroundStyle(theme.accent.color)
            }
        }
        .frame(width: Space.s7, height: Space.s7)
        .contentShape(Rectangle())
        .animation(Motion.standard, value: progress)
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
                Text(download.sizeText)
                    .font(Typeface.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary.color)
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
