import SwiftUI
import TotalityUI

/// The Clock's home tile (issue 204, section 6). Small is a glance: the next alarm, or a running timer.
/// Medium lists the world cities with their times. Large is a workspace: running timers and the stopwatch
/// with Pause and Lap, and presets that start a timer from Home.
public struct ClockHomeTile: View {
    private let model: ClockModel
    private let size: TileSize
    private let onOpen: @MainActor () -> Void

    public init(model: ClockModel, size: TileSize, onOpen: @escaping @MainActor () -> Void = {}) {
        self.model = model
        self.size = size
        self.onOpen = onOpen
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                switch size {
                case .small: small(context.date)
                case .medium: medium(context.date)
                case .large: large(context.date)
                }
            }
            .tilePadding()
        }
    }

    private func open(_ tab: ClockModel.Tab) {
        model.requestedTab = tab
        onOpen()
    }

    // MARK: Small

    private func small(_ now: Date) -> some View {
        let theme = Theme.current
        let timer = model.timers.filter { !$0.isPaused }.min { $0.remaining(at: now) < $1.remaining(at: now) }
        return VStack(alignment: .leading, spacing: Space.s2) {
            TileHeader("Clock", systemImage: "alarm")
            Spacer(minLength: 0)
            if let timer {
                Text(ClockMath.duration(timer.remaining(at: now)))
                    .font(Typeface.title.weight(.bold)).monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                Text(timer.label.isEmpty ? "Timer" : timer.label)
                    .font(Typeface.tileDetail).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            } else if let next = model.nextAlarm {
                let parts = timeParts(hour: next.alarm.hour, minute: next.alarm.minute, calendar: model.calendar)
                HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                    Text(parts.time).font(Typeface.title.weight(.bold)).monospacedDigit()
                    Text(parts.suffix).font(Typeface.tileDetail)
                }
                .foregroundStyle(theme.textPrimary.color)
                Text(ClockMath.until(next.date, from: now))
                    .font(Typeface.tileDetail.weight(.semibold)).foregroundStyle(theme.accent.color)
            } else {
                Text("No alarms yet").font(Typeface.tileDetail).foregroundStyle(theme.textSecondary.color)
            }
        }
    }

    // MARK: Medium

    private func medium(_ now: Date) -> some View {
        let theme = Theme.current
        let cities = Array(model.items.shownCities.prefix(4))
        return VStack(alignment: .leading, spacing: Space.s3) {
            TileHeader("World clock", systemImage: "globe")
            if cities.isEmpty {
                Text("Add a city to see its time.")
                    .font(Typeface.tileDetail).foregroundStyle(theme.textSecondary.color)
            }
            TileList(cities) { city in
                let parts = cityTime(city, at: now, calendar: model.calendar)
                HStack {
                    Text(city.name).font(Typeface.tileRow).foregroundStyle(theme.textPrimary.color).lineLimit(1)
                    Spacer(minLength: Space.s2)
                    Text("\(parts.time) \(parts.suffix)").font(Typeface.tileRow.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                }
                .tileLink(city.name) { open(.world) }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Large

    private func large(_ now: Date) -> some View {
        let theme = Theme.current
        let watch = model.stopwatch
        return VStack(alignment: .leading, spacing: Space.s3) {
            TileHeader("Clock", systemImage: "timer")
            ForEach(model.timers.prefix(2)) { timer in
                HStack(spacing: Space.s2) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(timer.label.isEmpty ? "Timer" : timer.label).font(Typeface.tileDetail).foregroundStyle(theme.textSecondary.color)
                        Text(ClockMath.duration(timer.remaining(at: now))).font(Typeface.title).monospacedDigit().foregroundStyle(theme.textPrimary.color)
                    }
                    Spacer(minLength: 0)
                    TileButton(timer.isPaused ? "Resume" : "Pause", systemImage: timer.isPaused ? "play.fill" : "pause.fill") {
                        Task { timer.isPaused ? await model.resume(timer.id) : await model.pause(timer.id) }
                    }
                    .tileControl()
                }
            }
            HStack(spacing: Space.s2) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Stopwatch").font(Typeface.tileDetail).foregroundStyle(theme.textSecondary.color)
                    Text(ClockMath.duration(watch.elapsed(at: now), hundredths: true)).font(Typeface.title).monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                }
                Spacer(minLength: 0)
                if watch.isRunning {
                    TileButton("Lap", systemImage: "flag") { Task { await model.lap() } }.tileControl()
                    TileButton("Stop", systemImage: "pause.fill") { Task { await model.stopStopwatch() } }.tileControl()
                } else {
                    TileButton(watch.isReset ? "Start" : "Resume", systemImage: "play.fill", isProminent: true) { Task { await model.startStopwatch() } }.tileControl()
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.s2) {
                ForEach(model.items.shownPresets.prefix(3)) { preset in
                    TileButton("\(preset.name) \(ClockMath.length(preset.seconds))", systemImage: "play.fill") {
                        Task { await model.start(preset) }
                    }
                    .tileControl()
                }
            }
        }
    }
}
