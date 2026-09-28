import SwiftUI
import ScreenMateCore

/// First-run privacy walkthrough.
///
/// Four pages, in the order the questions actually occur to someone installing a
/// desktop assistant: what is this, what does it want, what leaves my Mac, how do
/// I turn it off. Every permission is optional and can be skipped; the app is
/// usable — typing to a text model — with none of them granted.
struct OnboardingView: View {
    @ObservedObject var model: AssistantViewModel
    /// Observed explicitly: SwiftUI redraws only for the objects a view watches.
    @ObservedObject var environment: AppEnvironment
    @State private var page = 0

    private let pageCount = 4

    init(model: AssistantViewModel) {
        self.model = model
        self.environment = model.environment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)

            Divider()

            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                if page < pageCount - 1 {
                    Button("Continue") { page += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start using ScreenMate") { model.completeOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 440, height: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: welcomePage
        case 1: permissionsPage
        case 2: dataPage
        default: controlPage
        }
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("ScreenMate", subtitle: "A small assistant that sits on your desktop.")

            bullet("mic", "Talk or type", "Hold the microphone button, or the \(environment.settings.voiceInputShortcut.displayString) shortcut. Typing works exactly as well.")
            bullet("rectangle.dashed.badge.record", "Ask about your screen", "Capture a window or drag out a region, then ask what it means.")
            bullet("globe", "Look things up", "Optional web search, with sources shown so you can check them.")
            bullet("speaker.wave.2", "Hear the answer", "Replies can be read aloud, and you can interrupt by talking.")

            Spacer()
            Text("Nothing is captured, recorded or sent anywhere until you ask for it. The next pages explain exactly what that means.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("What ScreenMate needs", subtitle: "All of it is optional. Grant only what you want to use.")

            ForEach(PermissionCapability.allCases) { capability in
                OnboardingPermissionRow(model: model, capability: capability)
            }

            Spacer()
            Text("You can change any of these later in Settings › Privacy, or in System Settings › Privacy & Security.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dataPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("What leaves your Mac", subtitle: "And what never does.")

            group("Sent to your AI provider, when you send a message", tint: .orange) {
                line("Your message text.")
                line("A screenshot — only if you captured one, approved the preview, and both screen switches are on.")
                line("Text read from that screenshot, with credentials and card numbers removed where they can be recognised.")
                line("The current date and time, and recent messages in this conversation.")
            }

            group("Sent to your search provider, only when web access is on", tint: .teal) {
                line("The search words the assistant chose. Never your screen.")
            }

            group("Never leaves this Mac", tint: .green) {
                line("Your API keys. They are stored in the macOS Keychain.")
                line("Screenshot files. Captures are held in memory and dropped after the reply.")
                line("Analytics. There are none.")
            }

            Spacer()
        }
    }

    private var controlPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Staying in control", subtitle: "Every switch is reachable in one click.")

            bullet("eye.slash", "Pause screen awareness", "The eye button in the panel header turns it off instantly, and discards anything held.")
            bullet("circle.fill", "See when it is watching or listening", "A red dot on the widget means the microphone is open. An orange dot means the screen is being read. They only appear when it is really happening.")
            bullet("hand.raised", "Approve anything that changes something", "Copying to your clipboard, opening a page, saving a note — each one asks first, and shows you exactly what it would do.")
            bullet("trash", "Delete everything", "Settings › Privacy removes every conversation, note and API key.")

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("One more thing")
                    .font(Theme.Typography.settingsHeader)
                Text("ScreenMate needs an API key from an AI provider to answer anything. Without one, it runs against a built-in offline demo so you can try the interface.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Button("Open provider settings") {
                    model.completeOnboarding()
                    model.isShowingSettings = true
                }
                .buttonStyle(.link)
                .font(Theme.Typography.caption)
            }
        }
    }

    // MARK: Building blocks

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.message)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func group<Content: View>(
        _ title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.Typography.messageMeta)
                .foregroundStyle(tint)
            content()
        }
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(.secondary)
    }
}

struct OnboardingPermissionRow: View {
    @ObservedObject var model: AssistantViewModel
    @ObservedObject var permissions: PermissionCenter
    let capability: PermissionCapability

    init(model: AssistantViewModel, capability: PermissionCapability) {
        self.model = model
        self.permissions = model.environment.permissions
        self.capability = capability
    }

    private var state: PermissionState { permissions.state(of: capability) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(state.isGranted ? .green : .secondary)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(capability.displayName)
                        .font(Theme.Typography.message)
                    Text("· \(capability.featureName)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Text(capability.rationale)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if capability.needsRelaunchAfterGranting && !state.isGranted {
                    Text("macOS needs ScreenMate to be reopened after you allow this.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            if state.isGranted {
                Text("Allowed")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            } else if state.canBeRequested {
                Button("Allow") {
                    Task { await permissions.request(capability) }
                }
                .font(Theme.Typography.caption)
            } else {
                Button("Settings") {
                    permissions.openSystemSettings(for: capability)
                }
                .font(Theme.Typography.caption)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
