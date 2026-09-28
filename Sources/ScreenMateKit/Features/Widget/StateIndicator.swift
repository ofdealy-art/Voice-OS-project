import SwiftUI
import ScreenMateCore

/// The animated dot at the heart of the collapsed widget.
///
/// One shape, one colour per state, and motion that means something: a pulse
/// while listening, a sweep while working, a steady ring at rest. Animation is
/// suppressed when the user has asked for reduced motion.
struct StateIndicator: View {
    let style: AssistantActivityStyle
    /// Live microphone level, 0…1. Only used while listening.
    var level: Float = 0
    var diameter: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    private var color: Color { Theme.stateColor(for: style) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.35), lineWidth: 2)
                .frame(width: diameter, height: diameter)

            switch style {
            case .listening:
                Circle()
                    .fill(color)
                    .frame(width: diameter * 0.45, height: diameter * 0.45)
                    .scaleEffect(1 + CGFloat(min(level, 1)) * 0.7)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)

            case .working, .web, .screen:
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(reduceMotion ? 0 : phase * 360))
                    .onAppear { startSweep() }
                if reduceMotion {
                    Circle()
                        .fill(color)
                        .frame(width: diameter * 0.35, height: diameter * 0.35)
                }

            case .speaking:
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: diameter * 0.45, weight: .semibold))
                    .foregroundStyle(color)

            case .awaitingApproval:
                Image(systemName: "questionmark")
                    .font(.system(size: diameter * 0.55, weight: .bold))
                    .foregroundStyle(color)

            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: diameter * 0.55, weight: .bold))
                    .foregroundStyle(color)

            case .idle:
                Circle()
                    .fill(color.opacity(0.55))
                    .frame(width: diameter * 0.3, height: diameter * 0.3)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func startSweep() {
        guard !reduceMotion else { return }
        phase = 0
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

/// A row of bars driven by recent microphone levels.
struct VoiceWaveformView: View {
    let levels: [Float]
    var height: CGFloat = 22
    var tint: Color = .red

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                let level = levels[index]
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.35 + Double(level) * 0.65))
                    .frame(width: 2, height: barHeight(for: level))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int((levels.last ?? 0) * 100)) percent")
    }

    private func barHeight(for level: Float) -> CGFloat {
        let minimum: CGFloat = 3
        return minimum + (height - minimum) * CGFloat(min(max(level, 0), 1))
    }
}
