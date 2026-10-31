import SwiftUI
import TotalityUI

/// The Listen transport. Speech is generated on this device, so text never leaves it to be read.
struct ListenBar: View {
    let listen: ListenController

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(listen.current?.title ?? "")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let track = listen.current {
                    // In a long file one sentence is less than a pixel of bar, so this shows it's moving.
                    Text(Self.label(forSentence: listen.sentence, of: track.script.sentences.count))
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .monospacedDigit()
                        .accessibilityLabel("Sentence \(Self.label(forSentence: listen.sentence, of: track.script.sentences.count))")
                }
            }
            ListenProgress(value: listen.progress)
            HStack(spacing: 0) {
                control("gobackward", label: "Previous sentence") { listen.skip(by: -1) }
                control(listen.isPaused ? "play.fill" : "pause.fill", label: listen.isPaused ? "Play" : "Pause") {
                    listen.togglePause()
                }
                control("goforward", label: "Next sentence") { listen.skip(by: 1) }
                Spacer(minLength: 0)
                speedMenu
                voiceMenu
                control("xmark", label: "Stop listening") { listen.stop() }
            }
            .foregroundStyle(theme.textPrimary.color)
        }
        .padding(Space.s4)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func control(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).modifier(TapTarget())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(ListenController.speeds, id: \.self) { speed in
                Button(Self.label(forSpeed: speed)) { listen.setSpeed(speed) }
            }
        } label: {
            Text(Self.label(forSpeed: listen.speed)).font(Typeface.callout).modifier(TapTarget())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Speed")
    }

    private var voiceMenu: some View {
        Menu {
            Button("System default") { listen.setVoice(nil) }
            ForEach(listen.voices) { voice in
                Button("\(voice.name) (\(voice.language))") { listen.setVoice(voice.id) }
            }
        } label: {
            Image(systemName: "person.wave.2").modifier(TapTarget())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Voice")
    }

    static func label(forSentence index: Int, of count: Int) -> String {
        "\((index + 1).formatted()) of \(count.formatted())"
    }

    static func label(forSpeed speed: Double) -> String {
        "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

private struct TapTarget: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minWidth: Space.s7, minHeight: Space.s7)
            .contentShape(Rectangle())
    }
}

/// Drawn from tokens so it matches the surface it sits on.
private struct ListenProgress: View {
    let value: Double

    var body: some View {
        let theme = Theme.current
        Capsule()
            .fill(theme.surfaceSunken.color)
            .frame(height: Space.s1)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(theme.accent.color)
                        // Never narrower than it is tall, or the start of a long file draws as a sliver.
                        .frame(width: max(proxy.size.height, proxy.size.width * min(max(value, 0), 1)))
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Listening progress")
            .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
    }
}
