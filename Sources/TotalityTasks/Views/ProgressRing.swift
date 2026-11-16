import SwiftUI
import TotalityUI

/// Today's progress as a ring: one segment per list, each filling as its tasks are done. The track is
/// flat, and the segments keep to the one accent: the accent itself, then lighter washes of it, then grey.
struct ProgressRing: View {
    let progress: TodayProgress
    var diameter: CGFloat = Space.s7
    var lineWidth: CGFloat = Space.s1 + Space.s1 / 2
    /// One segment for the whole day, as on the home tile.
    var isWhole = false

    private struct Arc: Identifiable {
        let id: String
        let start: Double
        let end: Double
        let fill: Double
        let tone: Color
    }

    var body: some View {
        let theme = Theme.current
        ZStack {
            ForEach(arcs) { arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(theme.surfaceSunken.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle()
                    .trim(from: arc.start, to: arc.start + (arc.end - arc.start) * arc.fill)
                    .stroke(arc.tone, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .opacity(arc.fill > 0 ? 1 : 0)
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .animation(Motion.standard, value: progress)
        .accessibilityHidden(true)
    }

    private var arcs: [Arc] {
        let parts = isWhole || progress.parts.count < 2
            ? [TodayProgress.Part(id: "today", name: "Today", done: progress.done, planned: progress.planned)]
            : progress.parts
        let total = Double(max(progress.planned, 1))
        // Round caps reach past each end, so the gap leaves room for them as well as a little air.
        let gap = parts.count < 2 ? 0 : (lineWidth + Space.s1) / (Double.pi * (diameter - lineWidth))
        var start = 0.0
        return parts.enumerated().map { index, part in
            let share = Double(part.planned) / total
            let arc = Arc(
                id: part.id, start: start + gap / 2, end: max(start + gap / 2, start + share - gap / 2),
                fill: part.planned == 0 ? 0 : Double(part.done) / Double(part.planned), tone: Self.tone(index)
            )
            start += share
            return arc
        }
    }

    /// The accent, then washes of it, then a quiet grey: never a second hue.
    static func tone(_ index: Int) -> Color {
        let theme = Theme.current
        return [theme.accent.color, theme.highlightStrong.color, theme.textTertiary.color, theme.highlight.color][index % 4]
    }
}

/// The ring at the top of Today, larger, with "3 of 7" inside and each list's share under it.
struct TodayProgressView: View {
    let progress: TodayProgress

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s3) {
            ProgressRing(progress: progress, diameter: Space.s8 * 2, lineWidth: Space.s3)
                .overlay {
                    VStack(spacing: 0) {
                        Text(progress.count)
                            .font(Typeface.title)
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary.color)
                            .contentTransition(.numericText())
                        Text("done")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
            if progress.parts.count > 1 {
                // Centred on one line under the ring when it fits, wrapping when it doesn't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s3) { legend }
                    FlowRow(spacing: Space.s3) { legend }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.standard, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.spoken)
    }

    @ViewBuilder private var legend: some View {
        let theme = Theme.current
        ForEach(Array(progress.parts.enumerated()), id: \.element.id) { index, part in
            HStack(spacing: Space.s1) {
                Circle().fill(ProgressRing.tone(index)).frame(width: Space.s2, height: Space.s2)
                Text(part.name)
                    .foregroundStyle(theme.textPrimary.color)
                Text("\(part.done) of \(part.planned)")
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary.color)
            }
            .font(Typeface.caption)
        }
    }
}
