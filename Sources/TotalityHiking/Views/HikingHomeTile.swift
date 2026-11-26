import SwiftUI
import TotalityCore
import TotalityUI

/// Hiking's home tile (issue 240). Small is the last hike, medium is the month so far, and large lists the
/// trails nearby. A hike being recorded takes over every size.
public struct HikingHomeTile: View {
    private let model: HikingModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    public init(model: HikingModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            if let recording = model.recording {
                recordingFace(recording)
            } else {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .tilePadding()
    }

    private func quiet(_ line: String) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            TileHeader("Hiking", systemImage: "figure.hiking")
            Spacer(minLength: 0)
            Text(line)
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
        }
    }

    private func recordingFace(_ recording: HikingModel.Recording) -> some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s1) {
            TileHeader(recording.track.isPaused ? "Paused" : "Recording", systemImage: "record.circle", isTinted: true)
            Text(model.units.distance(recording.track.metres))
                .font(Typeface.display)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
            Text(recording.title)
                .font(Typeface.tileDetail)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var small: some View {
        let theme = Theme.current
        if let last = model.hikes.first {
            VStack(alignment: .leading, spacing: Space.s1) {
                TileHeader("Hiking", systemImage: "figure.hiking")
                Text(model.units.distance(last.metres))
                    .font(Typeface.display)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                Text(last.title)
                    .font(Typeface.tileLabel)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Text("\(model.units.climb(last.climb)) · \(last.startedAt.formatted(.dateTime.weekday(.wide)))")
                    .font(Typeface.tileDetail)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else {
            quiet("Record a hike or find trails nearby")
        }
    }

    @ViewBuilder
    private var medium: some View {
        let theme = Theme.current
        let month = model.month()
        if model.hikes.isEmpty {
            nearbyList(limit: 2)
        } else {
            VStack(alignment: .leading, spacing: Space.s1) {
                TileHeader("Hiking", systemImage: "figure.hiking")
                Text(model.units.distance(month.metres))
                    .font(Typeface.display)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                Text("This month · \(month.count == 1 ? "1 hike" : "\(month.count) hikes")")
                    .font(Typeface.tileDetail)
                    .foregroundStyle(theme.textSecondary.color)
                if let last = model.hikes.first {
                    Text("Last: \(last.title)")
                        .font(Typeface.tileDetail)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var large: some View {
        nearbyList(limit: 5)
    }

    @ViewBuilder
    private func nearbyList(limit: Int) -> some View {
        let theme = Theme.current
        if model.nearby.isEmpty {
            quiet(model.nearbyState == .offline ? "You're offline. Saved trails still open." : "Open Hiking to find trails nearby")
        } else {
            VStack(alignment: .leading, spacing: Space.s2) {
                TileHeader("Hiking · Nearby", systemImage: "figure.hiking")
                ForEach(model.nearby.prefix(limit)) { trail in
                    HStack(spacing: Space.s2) {
                        Text(trail.name)
                            .font(Typeface.tileRow)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                        Spacer(minLength: Space.s1)
                        Text(model.units.distance(trail.metres))
                            .font(Typeface.tileDetail)
                            .monospacedDigit()
                            .foregroundStyle(theme.textSecondary.color)
                        DifficultyBadge(difficulty: trail.difficulty, short: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .onTapGesture { onOpen() }
        }
    }
}
