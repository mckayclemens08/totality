import SwiftUI
import TotalityUI

/// AI model and privacy settings (issue 252 + next-up spec): runs on a local open 3-4B 4-bit model,
/// works without Apple Intelligence, and keeps everything off the network.
public struct AIModelView: View {
    @Bindable private var model: AIModel
    private let onDone: () -> Void

    public init(model: AIModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("Where Ask Totality thinks, and who can see what it reads.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)

                    optionCard(
                        title: "On this iPhone",
                        subtitle: "Qwen 2.5 1.5B 4-bit (~1.0 GB via llama.cpp). Runs offline on your device without Apple Intelligence.",
                        detail: "Runs locally on this device. Nothing leaves your phone.",
                        isSelected: true,
                        theme: theme
                    ) {
                        modelStatusControls(theme: theme)
                    }

                    optionCard(
                        title: "On your Mac · later",
                        subtitle: "Run a larger open model on your Mac over your own connection.",
                        detail: "Your Mac sees your question and what the AI reads. Not active yet.",
                        isSelected: false,
                        theme: theme
                    ) { EmptyView() }

                    optionCard(
                        title: "Hosted model, ask each time · later",
                        subtitle: "Optional cloud model, used only after you approve each context item by title.",
                        detail: "The provider sees only what you approve to send. Not active yet.",
                        isSelected: false,
                        theme: theme
                    ) { EmptyView() }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Model and privacy")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .tint(theme.accent.color)
    }

    private func optionCard<Footer: View>(
        title: String,
        subtitle: String,
        detail: String,
        isSelected: Bool,
        theme: Theme,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack {
                Text(title)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: 0)
                Circle()
                    .strokeBorder(isSelected ? theme.accent.color : theme.textSecondary.color, lineWidth: 2)
                    .background(Circle().fill(isSelected ? theme.accent.color : Color.clear).padding(4))
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(subtitle)
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(Typeface.caption)
                .foregroundStyle(isSelected ? theme.success.color : theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            footer()
        }
        .itemCard()
        .opacity(isSelected ? 1 : 0.78)
    }

    @ViewBuilder
    private func modelStatusControls(theme: Theme) -> some View {
        switch model.localModelStatus {
        case .ready(let name, _):
            HStack(spacing: Space.s3) {
                Label("\(name) ready", systemImage: "checkmark.circle.fill")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.success.color)
                Spacer(minLength: 0)
                HeaderPill("Remove") {
                    Task { await model.removeLocalModel() }
                }
            }
        case .notDownloaded:
            HeaderPill("Download local model (~1.0 GB)", systemImage: "arrow.down.circle.fill", isProminent: true) {
                Task { await model.downloadLocalModel() }
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: Space.s2) {
                ProgressView(value: progress)
                    .tint(theme.accent.color)
                HStack {
                    Text("Downloading Qwen 2.5 1.5B… \(Int((progress * 100).rounded()))%")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    HeaderPill("Cancel") {
                        model.cancelModelDownload()
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(message)
                    .font(Typeface.caption)
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
                HeaderPill("Retry download", isProminent: true) {
                    Task { await model.downloadLocalModel() }
                }
            }
        }
    }
}
