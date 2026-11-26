import SwiftUI
import TotalityCore
import TotalityUI

/// One trail: the route on the map, its figures, the elevation profile, and Save for offline.
struct TrailDetailView: View {
    let model: HikingModel
    let trailID: String
    let onClose: () -> Void
    let onStart: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                if let trail = model.trail(trailID) {
                    content(trail)
                        .padding(Space.s4)
                        .task { await model.lookUpProfile(trail) }
                } else {
                    HikingMessage(systemImage: "map", title: "This trail isn't here any more", detail: "Pull down on Nearby for a fresh list.")
                }
            }
            .background(theme.bg.color)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: onClose) }
            }
        }
    }

    @ViewBuilder
    private func content(_ trail: Trail) -> some View {
        let theme = Theme.current
        let units = model.units
        VStack(alignment: .leading, spacing: Space.s4) {
            ScreenTitle(trail.name, subtitle: [trail.kind, trail.surface?.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }.joined(separator: " · "))
            RouteMap(lines: trail.lines, here: model.here)
                .frame(height: Space.s8 * 4)
            Text(trail.isImported ? "Map: Apple Maps · Route from a GPX file" : "Map: Apple Maps · \(OverpassTrails.credit)")
                .font(Typeface.micro)
                .foregroundStyle(theme.textSecondary.color)
            HStack(spacing: Space.s3) {
                StatBox(value: units.distance(trail.metres), label: "Distance")
                StatBox(value: trail.climb.map(units.climb) ?? "–", label: "Climb")
                StatBox(value: trail.highest.map(units.height) ?? "–", label: "High point")
            }
            HikingCard("Elevation") {
                HStack {
                    Spacer()
                    DifficultyBadge(difficulty: trail.difficulty)
                }
                if let profile = trail.profile, profile.count > 1 {
                    ElevationProfile(heights: profile, units: units)
                    Text(OpenMeteoElevation.credit)
                        .font(Typeface.micro)
                        .foregroundStyle(theme.textSecondary.color)
                } else {
                    Text(trail.isImported ? "No elevation in this file" : model.isSaved(trail) || model.nearbyState == .offline ? "No elevation yet. It's looked up when you're online." : "Looking up the elevation")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            if model.isSaved(trail) {
                Label("Saved on this iPhone. The route and details open with no signal.", systemImage: "checkmark.circle.fill")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.success.color)
                Button("Remove from saved") { Task { await model.forget(trail) } }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.danger.color)
            } else {
                Button {
                    Task { await model.save(trail) }
                } label: {
                    Label("Save for offline", systemImage: "arrow.down.circle")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.textPrimary.color)
                        .frame(maxWidth: .infinity)
                        .padding(Space.s3)
                        .neumorphic(.raised, in: Capsule())
                }
                .buttonStyle(SoftPress())
            }
            Button {
                model.startRecording(on: trail)
                onStart()
            } label: {
                Text("Start this hike")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.accentOn.color)
                    .frame(maxWidth: .infinity)
                    .padding(Space.s4)
                    .background(Capsule().fill(theme.accent.color))
            }
            .buttonStyle(SoftPress())
            .disabled(model.recording != nil || model.locationAccess == .denied)
            if let url = trail.sourceURL {
                Button("See it on OpenStreetMap") { openURL(url) }
                    .font(Typeface.caption)
                    .foregroundStyle(theme.accent.color)
            }
        }
    }
}

/// Recording: the time, the figures, and the line so far. Pause and Finish; Finish seals the hike.
struct RecordingView: View {
    let model: HikingModel
    let onClose: () -> Void
    @State private var confirmsDiscard = false

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s4) {
            HStack {
                Button("Hide", action: onClose)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer()
                if let recording = model.recording {
                    Label(recording.track.isPaused ? "Paused" : "Recording", systemImage: recording.track.isPaused ? "pause.circle" : "record.circle")
                        .font(Typeface.tileLabel)
                        .foregroundStyle(recording.track.isPaused ? theme.textSecondary.color : theme.danger.color)
                }
            }
            if let recording = model.recording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(HikeUnits.duration(recording.track.movingSeconds))
                        .font(Typeface.display)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                }
                Text(recording.title)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textSecondary.color)
                HStack(spacing: Space.s3) {
                    StatBox(value: model.units.distance(recording.track.metres), label: "Distance")
                    StatBox(value: model.units.climb(recording.track.climb), label: "Climb")
                    StatBox(value: model.units.pace(seconds: recording.track.movingSeconds, metres: recording.track.metres), label: "Pace")
                }
                if let height = recording.track.lastFix?.elevation {
                    Text("Altitude \(model.units.height(height))")
                        .font(Typeface.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                }
                RouteMap(lines: (recording.trail?.lines ?? []) + recording.track.kept, here: recording.track.lastFix, followsHere: true)
                    .frame(maxHeight: .infinity)
                Label("Works with no signal. Where you are stays on this iPhone.", systemImage: "checkmark.shield")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.success.color)
                HStack(spacing: Space.s3) {
                    Button {
                        if recording.track.isPaused { model.resume() } else { model.pause() }
                    } label: {
                        Text(recording.track.isPaused ? "Resume" : "Pause")
                            .font(Typeface.headline)
                            .foregroundStyle(theme.textPrimary.color)
                            .frame(maxWidth: .infinity)
                            .padding(Space.s4)
                            .neumorphic(.raised, in: Capsule())
                    }
                    Button {
                        Task {
                            await model.finish()
                            onClose()
                        }
                    } label: {
                        Text("Finish")
                            .font(Typeface.headline)
                            .foregroundStyle(theme.accentOn.color)
                            .frame(maxWidth: .infinity)
                            .padding(Space.s4)
                            .background(Capsule().fill(theme.accent.color))
                    }
                }
                .buttonStyle(SoftPress())
                Button("Discard this hike", role: .destructive) { confirmsDiscard = true }
                    .font(Typeface.caption)
                    .foregroundStyle(theme.danger.color)
            } else {
                Spacer()
                HikingMessage(systemImage: "figure.hiking", title: "Not recording", detail: "Tap Record on Hiking to start.")
                Spacer()
            }
        }
        .padding(Space.s4)
        .background(theme.bg.color)
        .confirmationDialog("Discard this hike?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                model.discard()
                onClose()
            }
        } message: {
            Text("The track so far isn't saved.")
        }
    }
}

/// One recorded hike: its line, its figures, Share to Social, Rename and Delete.
struct HikeDetailView: View {
    let model: HikingModel
    let hike: Hike
    let onClose: () -> Void
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var exporting = false

    var body: some View {
        let theme = Theme.current
        let units = model.units
        let current = model.hikes.first { $0.id == hike.id } ?? hike
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    ScreenTitle(current.title, subtitle: current.startedAt.formatted(date: .complete, time: .shortened))
                    RouteMap(lines: current.segments)
                        .frame(height: Space.s8 * 4)
                    HStack(spacing: Space.s3) {
                        StatBox(value: units.distance(current.metres), label: "Distance")
                        StatBox(value: units.climb(current.climb), label: "Climb")
                        StatBox(value: HikeUnits.shortDuration(current.seconds), label: "Moving")
                    }
                    HStack(spacing: Space.s3) {
                        StatBox(value: units.pace(seconds: current.seconds, metres: current.metres), label: "Pace")
                        StatBox(value: current.highest.map(units.height) ?? "–", label: "High point")
                    }
                    let heights = current.points.compactMap(\.elevation)
                    if heights.count > 1 {
                        HikingCard("Elevation") { ElevationProfile(heights: GeoLine.sampled(current.points, count: 120).compactMap(\.elevation), units: units) }
                    }
                    Label("Sealed on this iPhone with your key. It isn't uploaded.", systemImage: "lock.fill")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                    if model.onShare != nil {
                        Button {
                            model.share(current, image: ShareCard.jpeg(current, units: units))
                            onClose()
                        } label: {
                            Label("Share to Social", systemImage: "square.and.arrow.up")
                                .font(Typeface.headline)
                                .foregroundStyle(theme.accentOn.color)
                                .frame(maxWidth: .infinity)
                                .padding(Space.s4)
                                .background(Capsule().fill(theme.accent.color))
                        }
                        .buttonStyle(SoftPress())
                        Text("Opens a post for you to check first. The picture leaves off the first and last \(units.distance(HikingModel.privacyTrim)), so it doesn't show where you started.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: onClose) }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Rename", systemImage: "pencil") {
                            newTitle = current.title
                            renaming = true
                        }
                        Button("Export GPX", systemImage: "square.and.arrow.up") { exporting = true }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.delete(current)
                            onClose()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .sheet(isPresented: $exporting) {
                GPXExportView(model: model, hike: current) { exporting = false }
            }
            .alert("Rename hike", isPresented: $renaming) {
                TextField("Name", text: $newTitle)
                Button("Rename") { Task { await model.rename(current, to: newTitle) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
