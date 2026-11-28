import SwiftUI
import TotalityCore
import TotalityUI

/// Home tile for Music (`ModuleID.player`), supporting Small, Medium, and Large sizes.
public struct MusicHomeTile: View {
    private let model: MusicModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    public init(model: MusicModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        let theme = Theme.current
        Group {
            switch size {
            case .small: smallView(theme: theme)
            case .medium: mediumView(theme: theme)
            case .large: largeView(theme: theme)
            }
        }
        .tilePadding()
        .accessibilityElement(children: .combine)
    }

    private func smallView(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            TileHeader("Music", systemImage: "music.note", isTinted: model.player.isPlaying)
            Spacer(minLength: 0)
            if let track = model.player.currentTrack ?? model.catalog.tracks.first {
                Text(track.title)
                    .font(Typeface.tileDetail)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                HStack(spacing: Space.s2) {
                    Text(track.source.displayName)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    playPill(for: track, theme: theme)
                }
            } else {
                Text("Add files or connect a service")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(2)
            }
        }
    }

    private func mediumView(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            TileHeader("Music", systemImage: "music.note", isTinted: model.player.isPlaying)
            Spacer(minLength: 0)
            if let track = model.player.currentTrack ?? model.catalog.tracks.first {
                HStack(spacing: Space.s3) {
                    VStack(alignment: .leading, spacing: Space.s1 / 2) {
                        Text(track.title)
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                        Text("\(track.subtitle) · \(track.source.privacyBadge)")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    playPill(for: track, theme: theme)
                }
                if model.player.currentTrack != nil {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.highlight.color)
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(theme.accent.color)
                                    .frame(width: max(0, proxy.size.width * model.player.progress), height: 4)
                            }
                    }
                    .frame(height: 4)
                }
            } else {
                Text("Upload encrypted audio files, connect OpenSubsonic, or link Spotify, Apple Music, or YouTube Music.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(2)
            }
        }
    }

    private func largeView(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            mediumView(theme: theme)
            if !model.catalog.tracks.isEmpty {
                Divider().overlay(theme.shadowDark.color.opacity(0.18))
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(model.catalog.tracks.prefix(3)) { track in
                        Button {
                            Task { await model.play(track) }
                        } label: {
                            HStack(spacing: Space.s2) {
                                Image(systemName: track.source.systemImage)
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.accent.color)
                                    .accessibilityHidden(true)
                                Text(track.title)
                                    .font(Typeface.callout)
                                    .foregroundStyle(theme.textPrimary.color)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(track.formattedDuration)
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.textSecondary.color)
                                    .monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func playPill(for track: MusicTrack, theme: Theme) -> some View {
        let isCurrentPlaying = model.player.currentTrack?.id == track.id && model.player.isPlaying
        return Button {
            if model.player.currentTrack?.id == track.id {
                model.player.togglePause()
            } else {
                Task { await model.play(track) }
            }
        } label: {
            Image(systemName: isCurrentPlaying ? "pause.fill" : "play.fill")
                .font(Typeface.caption.weight(.semibold))
                .foregroundStyle(theme.accentOn.color)
                .frame(width: Space.s6, height: Space.s6)
                .background(theme.accent.color, in: Circle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(isCurrentPlaying ? "Pause \(track.title)" : "Play \(track.title)")
    }
}
