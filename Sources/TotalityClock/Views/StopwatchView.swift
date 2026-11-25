import SwiftUI
import TotalityUI

/// Start, lap, stop and reset, with the laps listed and the fastest and slowest marked. It's a start time,
/// so it keeps counting with the app closed, and the laps sync.
struct StopwatchView: View {
    let model: ClockModel

    var body: some View {
        let watch = model.stopwatch
        ScrollView {
            VStack(spacing: Space.s5) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !watch.isRunning)) { context in
                    let now = watch.isRunning ? context.date : model.now
                    Dial(elapsed: watch.elapsed(at: now), lap: watch.laps.isEmpty ? nil : watch.currentLap(at: now))
                }
                HStack(spacing: Space.s4) {
                    if watch.isRunning {
                        ClockButton(title: "Lap", systemImage: "flag") { Task { await model.lap() } }
                        ClockButton(title: "Stop", systemImage: "pause.fill", isProminent: true) { Task { await model.stopStopwatch() } }
                    } else {
                        ClockButton(title: "Reset", systemImage: "arrow.counterclockwise") { Task { await model.resetStopwatch() } }
                            .disabled(watch.isReset)
                            .opacity(watch.isReset ? Motion.pressOpacity : 1)
                        ClockButton(title: watch.isReset ? "Start" : "Resume", systemImage: "play.fill", isProminent: true) {
                            Task { await model.startStopwatch() }
                        }
                    }
                }
                if !watch.laps.isEmpty { laps(watch) }
            }
            .padding(Space.s4)
        }
    }

    private func laps(_ watch: Stopwatch) -> some View {
        let theme = Theme.current
        let fastest = watch.fastestLap
        let slowest = watch.slowestLap
        return VStack(spacing: Space.s2) {
            Text("Laps").clockHeading()
            VStack(spacing: 0) {
                ForEach(Array(watch.laps.enumerated().reversed()), id: \.offset) { index, lap in
                    HStack {
                        Text("Lap \(index + 1)")
                            .foregroundStyle(theme.textPrimary.color)
                        if index == fastest {
                            Text("Fastest").font(Typeface.micro).foregroundStyle(theme.success.color)
                        } else if index == slowest {
                            Text("Slowest").font(Typeface.micro).foregroundStyle(theme.danger.color)
                        }
                        Spacer()
                        Text(ClockMath.duration(lap, hundredths: true))
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary.color)
                    }
                    .font(Typeface.body)
                    .padding(.vertical, Space.s2)
                    .accessibilityElement(children: .combine)
                }
            }
            .itemCard()
        }
    }
}

/// The running time in a raised round face, with the current lap under it.
private struct Dial: View {
    let elapsed: TimeInterval
    let lap: TimeInterval?

    var body: some View {
        let theme = Theme.current
        let side = Space.s8 * 4
        VStack(spacing: Space.s1) {
            Text(ClockMath.duration(elapsed, hundredths: true))
                .font(.system(size: Space.s7, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let lap {
                Text("Lap \(ClockMath.duration(lap, hundredths: true))")
                    .font(Typeface.callout)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(Space.s4)
        .frame(width: side, height: side)
        .neumorphic(.raised, in: Circle())
        .accessibilityElement(children: .combine)
    }
}
