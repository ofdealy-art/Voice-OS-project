import AppKit
import SwiftUI
import ScreenMateCore

/// The always-visible puck.
///
/// Click expands, drag moves the panel (handled by the window, which is
/// movable-by-background), and a right-click menu gives the actions that should
/// not need the panel open at all.
struct CollapsedWidgetView: View {
    @ObservedObject var model: AssistantViewModel
    // SwiftUI redraws only for objects a view observes, so the nested ones this
    // view reads are declared here rather than reached through `model`.
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var screen: ScreenAwarenessController

    @State private var isHovering = false

    init(model: AssistantViewModel) {
        self.model = model
        self.environment = model.environment
        self.screen = model.screen
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Metrics.collapsedCornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metrics.collapsedCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovering ? 0.18 : 0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)

            StateIndicator(style: model.activityStyle, level: currentLevel, diameter: 24)

            // Privacy indicators sit on the puck itself: whenever the microphone
            // is open or the screen is being read, it is visible without opening
            // anything.
            if model.activity.isCapturingAudio || screen.isReadingScreen {
                VStack {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(model.activity.isCapturingAudio ? Color.red : Color.orange)
                            .frame(width: 7, height: 7)
                            .padding(5)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: Theme.Metrics.collapsedSize, height: Theme.Metrics.collapsedSize)
        .onHover { isHovering = $0 }
        .onTapGesture { model.isPanelExpanded = true }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ScreenMate")
        .accessibilityValue(model.activity.shortLabel)
        .accessibilityHint("Open the assistant panel")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Open ScreenMate") { model.isPanelExpanded = true }
            Divider()
            Button(model.voice.isListening ? "Stop listening" : "Start voice input") {
                model.voice.toggle()
            }
            Button("Capture a region…") { model.captureScreen(scope: .selectedRegion) }
            Button("Capture the front window") { model.captureScreen(scope: .activeWindow) }
            Divider()
            Toggle("Screen awareness", isOn: Binding(
                get: { environment.settings.screenAwarenessEnabled },
                set: { _ in model.toggleScreenAwareness() }
            ))
            Toggle("Speak replies", isOn: Binding(
                get: { environment.settings.speakResponses },
                set: { environment.settings.speakResponses = $0 }
            ))
            Divider()
            Button("Settings…") { model.isShowingSettings = true }
            Button("Quit ScreenMate") { NSApp.terminate(nil) }
        }
    }

    private var currentLevel: Float {
        if case .listening(let level) = model.activity { return level }
        return 0
    }

    private var helpText: String {
        let shortcut = environment.settings.togglePanelShortcut.displayString
        return "\(model.activity.shortLabel) — click to open (\(shortcut))"
    }
}
