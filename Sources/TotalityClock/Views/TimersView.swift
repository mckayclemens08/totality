import SwiftUI
import TotalityUI

/// Several timers at once: the first big in a ring, the rest as rows, and presets that start one press.
struct TimersView: View {
    let model: ClockModel
    @State private var newTimer = false
    @State private var newPreset = false

    var body: some View {
        let timers = model.timers
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(spacing: Space.s4) {
                    if !model.ringsAsAlarm {
                        ClockNote(
                            systemImage: "exclamationmark.triangle",
                            text: "Timers need iOS 26 to ring like alarms. On \(SystemAlarms.systemName) each ends with a notification, which the silent switch mutes."
                        )
                        .padding(.horizontal, Space.s2)
                    }
                    if let first = timers.first {
                        BigTimer(model: model, timer: first, now: context.date)
                        ForEach(timers.dropFirst()) { timer in
                            TimerRow(model: model, timer: timer, now: context.date)
                        }
                    } else {
                        ClockEmpty(title: "No timers running", detail: "Start one from a preset, or set your own.", button: "New timer") { newTimer = true }
                    }
                    presets
                    if model.ringsAsAlarm {
                        ClockNote(systemImage: "bell", text: "Timers ring through silent mode and Focus.")
                            .padding(.horizontal, Space.s2)
                    }
                }
                .padding(Space.s4)
                .padding(.bottom, Metric.addButton + Space.s5)
            }
        }
        .addButton("New timer") { newTimer = true }
        .sheet(isPresented: $newTimer) {
            LengthSheet(title: "New timer", action: "Start") { seconds, label in
                newTimer = false
                if let seconds { Task { await model.startTimer(seconds: seconds, label: label) } }
            }
        }
        .sheet(isPresented: $newPreset) {
            LengthSheet(title: "New preset", action: "Save") { seconds, label in
                newPreset = false
                if let seconds { Task { await model.addPreset(name: label, seconds: seconds) } }
            }
        }
    }

    private var presets: some View {
        let theme = Theme.current
        return VStack(spacing: Space.s2) {
            Text("Presets").clockHeading()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s3 - Space.s1 / 2), count: 4), spacing: Space.s3) {
                ForEach(model.items.shownPresets) { preset in
                    Button {
                        Task { await model.start(preset) }
                    } label: {
                        PresetFace(top: ClockMath.length(preset.seconds), bottom: preset.name)
                    }
                    .buttonStyle(SoftPress())
                    .accessibilityLabel("Start \(preset.name), \(ClockMath.length(preset.seconds))")
                    .contextMenu {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { Task { await model.removePreset(preset.id) } }
                    }
                }
                Button { newPreset = true } label: {
                    PresetFace(top: "+", bottom: "New")
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel("New preset")
            }
            .foregroundStyle(theme.textPrimary.color)
        }
    }
}

private struct PresetFace: View {
    let top: String
    let bottom: String

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s1 / 4) {
            Text(top).font(Typeface.callout.weight(.bold)).foregroundStyle(theme.textPrimary.color)
            Text(bottom).font(Typeface.micro).foregroundStyle(theme.textSecondary.color).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: Space.s7 + Space.s3 - Space.s1 / 2)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm + Space.s1 + Space.s1 / 2, style: .continuous))
    }
}

/// The first timer, as the mockup draws it: a ring, the time left, and Cancel and Pause under it.
private struct BigTimer: View {
    let model: ClockModel
    let timer: RunningTimer
    let now: Date

    var body: some View {
        let theme = Theme.current
        let failed = model.failed.contains(timer.id)
        VStack(spacing: Space.s4) {
            if !timer.label.isEmpty {
                Text(timer.label).font(Typeface.title).foregroundStyle(theme.textPrimary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ProgressRing(progress: 1 - timer.progress(at: now), diameter: Space.s8 * 4) {
                VStack(spacing: Space.s1) {
                    Text(ClockMath.duration(timer.remaining(at: now)))
                        .font(.system(size: Space.s7, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                    Text("of \(ClockMath.length(timer.seconds))").font(Typeface.callout).foregroundStyle(theme.textSecondary.color)
                    if let end = timer.endsAt {
                        Text("Ends at \(end.formatted(date: .omitted, time: .shortened))")
                            .font(Typeface.caption.weight(.semibold))
                            .foregroundStyle(theme.accent.color)
                    } else {
                        Text("Paused").font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.textSecondary.color)
                    }
                }
            }
            if failed {
                Label("This timer won't ring. iOS didn't take it.", systemImage: "exclamationmark.triangle.fill")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.danger.color)
            }
            HStack(spacing: Space.s4) {
                ClockButton(title: "Cancel") { Task { await model.cancel(timer.id) } }
                if timer.isPaused {
                    ClockButton(title: "Resume", systemImage: "play.fill", isProminent: true) { Task { await model.resume(timer.id) } }
                } else {
                    ClockButton(title: "Pause", systemImage: "pause.fill", isProminent: true) { Task { await model.pause(timer.id) } }
                }
            }
        }
    }
}

private struct TimerRow: View {
    let model: ClockModel
    let timer: RunningTimer
    let now: Date

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(timer.label.isEmpty ? "Timer" : timer.label).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                Text(timer.endsAt.map { "Ends at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Paused")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            Text(ClockMath.duration(timer.remaining(at: now)))
                .font(Typeface.title)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
            HeaderButton(timer.isPaused ? "Resume \(timer.label)" : "Pause \(timer.label)", systemImage: timer.isPaused ? "play.fill" : "pause.fill") {
                Task { timer.isPaused ? await model.resume(timer.id) : await model.pause(timer.id) }
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .contextMenu {
            Button("Cancel timer", systemImage: "xmark", role: .destructive) { Task { await model.cancel(timer.id) } }
        }
    }
}

/// Hours, minutes and seconds, and a name, for a new timer or preset.
private struct LengthSheet: View {
    let title: String
    let action: String
    let onDone: (Int?, String) -> Void
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var label = ""

    var body: some View {
        let theme = Theme.current
        let total = hours * 3600 + minutes * 60 + seconds
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.s4) {
                    HStack(spacing: 0) {
                        wheel("Hours", $hours, 0..<24, "h")
                        wheel("Minutes", $minutes, 0..<60, "min")
                        wheel("Seconds", $seconds, 0..<60, "s")
                    }
                    .itemCard()
                    TextField("Name, like Tea", text: $label)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .raisedField()
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil, "") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action) { onDone(total, label) }.disabled(total == 0)
                }
            }
        }
        .tint(theme.accent.color)
        .presentationDetents([.medium, .large])
    }

    private func wheel(_ name: String, _ value: Binding<Int>, _ range: Range<Int>, _ unit: String) -> some View {
        Picker(name, selection: value) {
            ForEach(range, id: \.self) { Text("\($0) \(unit)").tag($0) }
        }
        #if os(iOS)
        .pickerStyle(.wheel)
        #endif
        .frame(maxWidth: .infinity)
    }
}
