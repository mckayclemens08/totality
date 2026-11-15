import SwiftUI
import TotalityCore

/// Settings' Storage section: how full the sealed store and the mailbox are, and each module's share.
/// While it's on screen it asks every 10 seconds, and the bars slide to each new value.
public struct StorageSection: View {
    let model: StorageModel

    public init(model: StorageModel) {
        self.model = model
    }

    public var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Storage")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            StorageBar(title: "Photos and files", meter: model.sealed)
            if let mailbox = model.mailbox {
                StorageBar(title: "Mailbox", meter: mailbox)
            }
            if !model.parts.isEmpty {
                StorageBreakdown(parts: model.parts)
            }
        }
        .task { await model.keepCurrent() }
    }
}

/// One allowance: its name, "4.2 GB of 20 GB", a raised track with the used part filled, and a warning
/// once it's nearly full.
struct StorageBar: View {
    let title: String
    let meter: StorageMeter

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: Space.s2)
                if let quota = meter.quota {
                    Text(quota.line)
                        .font(Typeface.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            StorageTrack(fraction: meter.quota?.fraction, level: meter.quota?.level ?? .fine)
            if let note {
                Text(note.text)
                    .font(Typeface.caption)
                    .foregroundStyle(note.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var note: (text: String, color: Color)? {
        let theme = Theme.current
        switch meter {
        case .loading:
            return nil
        case .failed(let reason):
            return (reason, theme.textSecondary.color)
        case .lastKnown(_, let at):
            return ("Offline. This is from \(at.formatted(date: .abbreviated, time: .shortened)).", theme.textSecondary.color)
        case .current(let quota):
            switch quota.level {
            case .fine: return nil
            case .nearlyFull: return ("Nearly full. Delete what you don't need to make room.", theme.textPrimary.color)
            case .almostFull: return ("Almost full. New things may not save until you make room.", theme.danger.color)
            }
        }
    }

    private var accessibility: String {
        guard let quota = meter.quota else { return "\(title), loading" }
        return "\(title), \(quota.line) used, \(Int((quota.fraction * 100).rounded())) percent"
    }
}

/// The track sits sunken into the page and the used part rises out of it. Grey while there's room, the
/// accent from 80%, and the danger colour from 95%. With nothing read yet it's an empty track that pulses.
struct StorageTrack: View {
    let fraction: Double?
    let level: StorageQuota.Level
    @State private var pulsing = false

    var body: some View {
        let theme = Theme.current
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceSunken.color)
                if let fraction {
                    Capsule()
                        .fill(fill)
                        // A sliver still shows for something tiny, so a used bar never looks empty.
                        .frame(width: max(fraction > 0 ? Space.s3 : 0, geometry.size.width * fraction))
                } else {
                    Capsule()
                        .fill(theme.surface.color)
                        .opacity(pulsing ? 0.9 : 0.3)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
                        }
                }
            }
        }
        .frame(height: Space.s3)
        .neumorphic(.pressed, in: Capsule())
        .animation(Motion.standard, value: fraction)
        .animation(Motion.standard, value: level)
    }

    private var fill: Color {
        let theme = Theme.current
        switch level {
        case .fine: return theme.textTertiary.color
        case .nearlyFull: return theme.accent.color
        case .almostFull: return theme.danger.color
        }
    }
}

/// Each module's share, as this device counts it.
struct StorageBreakdown: View {
    let parts: [StoragePart]

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(parts) { part in
                HStack {
                    Text(part.name)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                    Spacer(minLength: Space.s2)
                    Text(StorageQuota.bytes(part.bytes))
                        .font(Typeface.body)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            Text("On this device's count. The server holds everything sealed, so it can't tell what's what.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s3)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
    }
}
