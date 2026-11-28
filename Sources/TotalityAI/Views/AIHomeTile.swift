import SwiftUI
import TotalityCore
import TotalityUI

/// Ask Totality's Home tile (issue 252), showing a brief on-device summary from granted modules
/// and a direct button to ask. Never reads ungranted modules.
public struct AIHomeTile: View {
    private let model: AIModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void
    private let onAsk: @MainActor () -> Void

    public init(
        model: AIModel,
        size: TileSize,
        onOpen: @escaping @MainActor () -> Void = {},
        onAsk: (@MainActor () -> Void)? = nil
    ) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
        self.onAsk = onAsk ?? onOpen
    }

    public var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            TileHeader("Ask Totality", systemImage: "sparkles", isTinted: model.phase == .thinking)
            Spacer(minLength: 0)
            Text(summaryLine)
                .font(size == .small ? Typeface.tileDetail : Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(size == .large ? 4 : (size == .medium ? 3 : 2))
                .fixedSize(horizontal: false, vertical: true)
            if size != .small {
                HStack(spacing: Space.s2) {
                    Button(action: onAsk) {
                        HStack(spacing: Space.s2) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(theme.accent.color)
                                .accessibilityHidden(true)
                            Text("Ask")
                                .foregroundStyle(theme.textSecondary.color)
                            Spacer(minLength: 0)
                        }
                        .font(Typeface.callout)
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, Space.s2)
                        .neumorphic(.subtle, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(SoftPress())
                }
            }
            if size == .large {
                Text("Runs on this iPhone. Nothing leaves the device.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
        }
        .tilePadding()
        .accessibilityElement(children: .combine)
    }

    private var summaryLine: String {
        if model.phase == .thinking {
            return "Thinking on this iPhone…"
        }
        if !model.hasAnyGrant {
            return "Sees only what you allow. Choose what it can use."
        }
        if let last = model.messages.last(where: { $0.role == .assistant }) {
            return last.text.split(separator: "\n").first.map(String.init) ?? "Ready on this iPhone."
        }
        let grantedCount = model.grantedReadModules.count
        return grantedCount == 1
            ? "1 module granted. Runs locally on this iPhone."
            : "\(grantedCount) modules granted. Runs locally on this iPhone."
    }
}
