import SwiftUI
import ScreenMateCore

/// Text field, send, microphone, capture and stop.
///
/// Typing and talking are given the same weight: the microphone button sits next
/// to send at the same size, and both have a visible shortcut in their tooltip.
struct ComposerView: View {
    @ObservedObject var model: AssistantViewModel
    // Observed explicitly: SwiftUI redraws only for the objects a view watches.
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var voice: VoiceController
    @ObservedObject var screen: ScreenAwarenessController

    @FocusState private var isInputFocused: Bool

    init(model: AssistantViewModel) {
        self.model = model
        self.environment = model.environment
        self.voice = model.voice
        self.screen = model.screen
    }

    var body: some View {
        VStack(spacing: 6) {
            if voice.isListening || !voice.partialTranscript.isEmpty {
                listeningStrip
            }

            if let summary = model.attachmentSummary {
                HStack(spacing: 6) {
                    InfoPill(
                        systemImage: "photo.badge.checkmark",
                        text: summary,
                        tint: .orange,
                        onDismiss: { screen.discard() }
                    )
                    Spacer(minLength: 0)
                }
            }

            HStack(alignment: .bottom, spacing: 4) {
                TextField("Ask about your screen, or anything", text: $model.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.message)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityLabel("Message")
                    .accessibilityHint("Type a message, then press Return to send")

                CompactButton(
                    systemImage: voice.isListening ? "mic.fill" : "mic",
                    help: micHelp,
                    role: voice.isListening ? .destructive : .normal,
                    isActive: voice.isListening
                ) {
                    voice.toggle()
                }

                CompactButton(
                    systemImage: "rectangle.dashed.badge.record",
                    help: captureHelp,
                    isActive: screen.isReadingScreen || screen.attachedContext != nil
                ) {
                    model.captureScreen()
                }
                .contextMenu {
                    Button("Front window") { model.captureScreen(scope: .activeWindow) }
                    Button("Whole display") { model.captureScreen(scope: .activeDisplay) }
                    Button("Select a region…") { model.captureScreen(scope: .selectedRegion) }
                }

                if model.isBusy || model.activity == .speaking {
                    CompactButton(
                        systemImage: "stop.fill",
                        help: "Stop (Esc)",
                        role: .destructive
                    ) {
                        model.stopGeneration()
                    }
                } else {
                    CompactButton(
                        systemImage: "arrow.up",
                        help: "Send (Return)",
                        role: .prominent,
                        isEnabled: model.canSend
                    ) {
                        send()
                    }
                }
            }
        }
        .onAppear { isInputFocused = true }
    }

    private var listeningStrip: some View {
        HStack(spacing: 8) {
            VoiceWaveformView(levels: voice.levels)
                .frame(width: 84)
            Text(voice.partialTranscript.isEmpty ? "Listening…" : voice.partialTranscript)
                .font(Theme.Typography.caption)
                .foregroundStyle(voice.partialTranscript.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            CompactButton(systemImage: "xmark", help: "Cancel voice input (Esc)") {
                voice.cancel()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .transition(.opacity)
    }

    private func send() {
        guard model.canSend else { return }
        model.sendComposer()
        isInputFocused = true
    }

    private var micHelp: String {
        let shortcut = environment.settings.voiceInputShortcut.displayString
        return voice.isListening
            ? "Stop listening and send (\(shortcut))"
            : "Start voice input (\(shortcut))"
    }

    private var captureHelp: String {
        let shortcut = environment.settings.captureRegionShortcut.displayString
        guard environment.settings.screenAwarenessEnabled else {
            return "Screen awareness is off — turn it on in Settings › Privacy"
        }
        return "Capture your screen. Right-click for options. Region: \(shortcut)"
    }
}
