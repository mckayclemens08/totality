import Foundation
import Observation

/// Honest origin badge for audio currently controlled by the shared transport.
public enum AudioSourceBadge: String, Codable, Sendable, Equatable {
    case uploaded = "End-to-end encrypted"
    case openSubsonic = "Direct to your server"
    case appleMusic = "Streamed via Apple Music"
    case spotify = "Controlled via Spotify"
    case youTubeMusic = "Streamed via YouTube"
    case readerListen = "On-device voice"
}

/// Snapshot of whichever module currently holds audio focus (`Reader` Listen or `Music`).
public struct NowPlayingSummary: Sendable, Equatable {
    public let module: ModuleID
    public let title: String
    public let subtitle: String
    public let badge: AudioSourceBadge
    public let isPlaying: Bool
    public let progress: Double

    public init(
        module: ModuleID,
        title: String,
        subtitle: String = "",
        badge: AudioSourceBadge,
        isPlaying: Bool,
        progress: Double = 0
    ) {
        self.module = module
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.isPlaying = isPlaying
        self.progress = progress
    }
}

/// Lightweight audio-focus coordinator in `TotalityCore` so Reader Listen and Music never play over
/// each other while preserving strict zero cross-module imports (docs/module-contracts.md).
@MainActor
@Observable
public final class AudioTransportCoordinator {
    public private(set) var activeModule: ModuleID?
    public private(set) var summary: NowPlayingSummary?
    @ObservationIgnored private var pauseHandlers: [ModuleID: @MainActor () -> Void] = [:]

    public init() {}

    public func registerPauseHandler(for module: ModuleID, pause: @escaping @MainActor () -> Void) {
        pauseHandlers[module] = pause
    }

    public func claimFocus(for module: ModuleID, summary: NowPlayingSummary? = nil) {
        if let current = activeModule, current != module {
            pauseHandlers[current]?()
        }
        activeModule = module
        if let summary {
            self.summary = summary
        }
    }

    public func updateSummary(_ summary: NowPlayingSummary?) {
        guard let summary else {
            self.summary = nil
            return
        }
        if activeModule == nil || activeModule == summary.module {
            activeModule = summary.module
            self.summary = summary
        }
    }

    public func releaseFocus(for module: ModuleID) {
        guard activeModule == module else { return }
        activeModule = nil
        summary = nil
    }
}
