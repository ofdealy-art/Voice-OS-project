import SwiftUI
import ScreenMateCore

public struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @ObservedObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: SettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.environment = viewModel.environment
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ScreenMate Settings")
                    .font(Theme.Typography.title)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Picker("", selection: $viewModel.selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)

            Divider().padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch viewModel.selectedTab {
                    case .provider: ProviderSettingsSection(viewModel: viewModel)
                    case .voice: VoiceSettingsSection(viewModel: viewModel)
                    case .privacy: PrivacySettingsSection(viewModel: viewModel)
                    case .web: WebSettingsSection(viewModel: viewModel)
                    case .general: GeneralSettingsSection(viewModel: viewModel)
                    }

                    if let status = viewModel.statusMessage {
                        Label(status, systemImage: "checkmark.circle")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 520)
        .onChange(of: viewModel.selectedTab) { _ in
            viewModel.clearMessages()
            viewModel.refreshPermissions()
        }
    }
}

// MARK: - Provider

struct ProviderSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isTesting = false

    var body: some View {
        SettingsGroup("AI provider") {
            Picker("Provider", selection: Binding(
                get: { viewModel.settings.chatProviderID },
                set: { viewModel.selectProvider($0) }
            )) {
                ForEach(viewModel.providers) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }

            Picker("Model", selection: Binding(
                get: { viewModel.settings.chatModelID },
                set: { viewModel.settings.chatModelID = $0 }
            )) {
                ForEach(viewModel.availableModels) { model in
                    Text(model.supportsVision ? "\(model.displayName) · sees images" : model.displayName)
                        .tag(model.id)
                }
            }

            if let descriptor = viewModel.selectedProvider {
                Text(descriptor.privacyNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if descriptor.requiresAPIKey {
                    HStack(spacing: 6) {
                        SecureField(
                            viewModel.hasStoredChatKey ? "A key is saved — type to replace it" : "Paste your API key",
                            text: $viewModel.chatKeyDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewModel.saveChatKey() }

                        Button("Save") { viewModel.saveChatKey() }
                            .disabled(viewModel.chatKeyDraft.isEmpty)
                    }

                    HStack(spacing: 10) {
                        Label(
                            viewModel.hasStoredChatKey ? "Stored in your Keychain" : "No key stored",
                            systemImage: viewModel.hasStoredChatKey ? "lock.fill" : "lock.open"
                        )
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)

                        if viewModel.hasStoredChatKey {
                            Button("Remove key") { viewModel.removeChatKey() }
                                .buttonStyle(.link)
                                .font(Theme.Typography.caption)
                        }
                        if let url = descriptor.apiKeyHelpURL {
                            Link("Get a key", destination: url)
                                .font(Theme.Typography.caption)
                        }
                    }
                }
            }

            HStack {
                Button(isTesting ? "Checking…" : "Test connection") {
                    isTesting = true
                    Task {
                        await viewModel.testConnection()
                        isTesting = false
                    }
                }
                .disabled(isTesting)
                Spacer()
            }
        }

        SettingsGroup("Response") {
            LabeledContent("Longest reply") {
                Stepper(
                    value: Binding(
                        get: { viewModel.settings.maxOutputTokens },
                        set: { viewModel.settings.maxOutputTokens = $0 }
                    ),
                    in: 256...8192,
                    step: 256
                ) {
                    Text("\(viewModel.settings.maxOutputTokens) tokens")
                        .font(Theme.Typography.caption)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Slider(
                    value: Binding(
                        get: { viewModel.settings.temperature },
                        set: { viewModel.settings.temperature = $0 }
                    ),
                    in: 0...1,
                    step: 0.05
                ) {
                    Text("Creativity")
                }
                Text("Lower is more literal and repeatable; higher is more varied.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Voice

struct VoiceSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsGroup("Listening") {
            Picker("Mode", selection: Binding(
                get: { viewModel.settings.voiceInputMode },
                set: { viewModel.settings.voiceInputMode = $0 }
            )) {
                ForEach(VoiceInputMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text(viewModel.settings.voiceInputMode == .pushToTalk
                 ? "The microphone is open only while you hold the button or shortcut."
                 : "The microphone stays open until you stop it, or after a pause in speech.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            Picker("Microphone", selection: Binding(
                get: { viewModel.settings.selectedMicrophoneUID ?? "" },
                set: { viewModel.settings.selectedMicrophoneUID = $0.isEmpty ? nil : $0 }
            )) {
                Text("System default").tag("")
                ForEach(viewModel.microphones) { device in
                    Text(device.isDefault ? "\(device.name) (default)" : device.name).tag(device.id)
                }
            }
            if viewModel.microphones.isEmpty {
                Label(
                    AppError.noAudioInputDevice.errorDescription ?? "",
                    systemImage: "exclamationmark.triangle"
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(.orange)
            }

            Picker("Language", selection: Binding(
                get: { viewModel.settings.speechRecognitionLocaleIdentifier },
                set: { viewModel.settings.speechRecognitionLocaleIdentifier = $0 }
            )) {
                ForEach(viewModel.speechLocales) { locale in
                    Text(locale.name).tag(locale.id)
                }
            }

            Toggle("Prefer on-device transcription", isOn: Binding(
                get: { viewModel.settings.preferOnDeviceSpeechRecognition },
                set: { viewModel.settings.preferOnDeviceSpeechRecognition = $0 }
            ))
            Text("When your Mac supports it for the chosen language, your voice is transcribed locally and never leaves the machine.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            PermissionRow(viewModel: viewModel, capability: .microphone)
            PermissionRow(viewModel: viewModel, capability: .speechRecognition)
        }

        SettingsGroup("Speaking") {
            Toggle("Read replies aloud", isOn: Binding(
                get: { viewModel.settings.speakResponses },
                set: { viewModel.settings.speakResponses = $0 }
            ))

            Picker("Voice", selection: Binding(
                get: { viewModel.settings.textToSpeechVoiceIdentifier ?? "" },
                set: { viewModel.settings.textToSpeechVoiceIdentifier = $0.isEmpty ? nil : $0 }
            )) {
                Text("System default").tag("")
                ForEach(viewModel.voices) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
            .disabled(!viewModel.settings.speakResponses)

            VStack(alignment: .leading, spacing: 2) {
                Slider(
                    value: Binding(
                        get: { viewModel.settings.speechRate },
                        set: { viewModel.settings.speechRate = $0 }
                    ),
                    in: 0.25...0.85,
                    step: 0.05
                ) {
                    Text("Speed")
                }
                .disabled(!viewModel.settings.speakResponses)

                HStack {
                    Button("Preview") { viewModel.previewVoice() }
                        .disabled(!viewModel.settings.speakResponses)
                    Button("Stop") { viewModel.stopPreview() }
                }
                .font(Theme.Typography.caption)
            }

            Toggle("Stop speaking when I start talking", isOn: Binding(
                get: { viewModel.settings.interruptSpeechWhenUserSpeaks },
                set: { viewModel.settings.interruptSpeechWhenUserSpeaks = $0 }
            ))
            .disabled(!viewModel.settings.speakResponses)
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsGroup("Screen awareness") {
            Toggle("Let ScreenMate look at my screen", isOn: Binding(
                get: { viewModel.settings.screenAwarenessEnabled },
                set: { viewModel.settings.screenAwarenessEnabled = $0 }
            ))
            Text("Off by default. Even when on, nothing is captured until you ask for it.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            Toggle("Send screen content to the AI provider", isOn: Binding(
                get: { viewModel.settings.sendScreenContentToProvider },
                set: { viewModel.settings.sendScreenContentToProvider = $0 }
            ))
            .disabled(!viewModel.settings.screenAwarenessEnabled)
            Text("Screen analysis needs this. Without it, captures stay on your Mac and ScreenMate cannot answer questions about them.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            Picker("Capture button takes", selection: Binding(
                get: { viewModel.settings.defaultCaptureScope },
                set: { viewModel.settings.defaultCaptureScope = $0 }
            )) {
                ForEach(ScreenCaptureScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }

            Toggle("Always show me the capture before sending", isOn: Binding(
                get: { viewModel.settings.alwaysPreviewBeforeSending },
                set: { viewModel.settings.alwaysPreviewBeforeSending = $0 }
            ))

            Toggle("Read text from captures on this Mac", isOn: Binding(
                get: { viewModel.settings.runOCROnCaptures },
                set: { viewModel.settings.runOCROnCaptures = $0 }
            ))

            Toggle("Remove credentials and card numbers from that text", isOn: Binding(
                get: { viewModel.settings.redactSensitiveContent },
                set: { viewModel.settings.redactSensitiveContent = $0 }
            ))
            .disabled(!viewModel.settings.runOCROnCaptures)
            Text("Pattern-based and best effort. It does not alter the picture itself, so check the preview.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            Toggle("Skip password managers and windows that look sensitive", isOn: Binding(
                get: { viewModel.settings.skipCaptureForSensitiveApps },
                set: { viewModel.settings.skipCaptureForSensitiveApps = $0 }
            ))

            PermissionRow(viewModel: viewModel, capability: .screenRecording)
            PermissionRow(viewModel: viewModel, capability: .accessibility)
        }

        SettingsGroup("Conversations") {
            Toggle("Save conversations on this Mac", isOn: Binding(
                get: { viewModel.settings.saveConversations },
                set: { viewModel.settings.saveConversations = $0 }
            ))
            Text("Saved as files in your Application Support folder. Screenshots are never saved — only a note that one was attached.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            Picker("Keep them for", selection: Binding(
                get: { viewModel.settings.conversationRetention },
                set: { viewModel.settings.conversationRetention = $0 }
            )) {
                ForEach(ConversationRetention.allCases) { retention in
                    Text(retention.displayName).tag(retention)
                }
            }
            .disabled(!viewModel.settings.saveConversations)

            Text(viewModel.storedDataDescription)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Show in Finder") { viewModel.revealDataFolder() }
                Button("Delete all conversations") { viewModel.deleteAllConversations() }
                Button("Delete everything…", role: .destructive) {
                    viewModel.isConfirmingDataDeletion = true
                }
            }
            .font(Theme.Typography.caption)
        }

        SettingsGroup("Analytics") {
            Label("ScreenMate collects no analytics and sends no telemetry.", systemImage: "checkmark.shield")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .alert("Delete everything ScreenMate has stored?", isPresented: Binding(
            get: { viewModel.isConfirmingDataDeletion },
            set: { viewModel.isConfirmingDataDeletion = $0 }
        )) {
            Button("Delete", role: .destructive) { viewModel.deleteEverything() }
            Button("Cancel", role: .cancel) { viewModel.isConfirmingDataDeletion = false }
        } message: {
            Text("This removes every saved conversation, every note ScreenMate wrote, and every API key from your Keychain. It cannot be undone.")
        }
    }
}

// MARK: - Web

struct WebSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsGroup("Web research") {
            Toggle("Let ScreenMate search the web", isOn: Binding(
                get: { viewModel.settings.webAccessEnabled },
                set: { viewModel.settings.webAccessEnabled = $0 }
            ))
            Text("Off by default. When on, ScreenMate can look things up and will show you its sources.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            Picker("Search provider", selection: Binding(
                get: { viewModel.settings.webSearchProviderID },
                set: { viewModel.settings.webSearchProviderID = $0 }
            )) {
                ForEach(viewModel.searchProviders) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .disabled(!viewModel.settings.webAccessEnabled)

            if let descriptor = viewModel.selectedSearchProvider {
                Text(descriptor.privacyNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    SecureField(
                        viewModel.hasStoredSearchKey ? "A key is saved — type to replace it" : "Search API key",
                        text: $viewModel.searchKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.saveSearchKey() }
                    Button("Save") { viewModel.saveSearchKey() }
                        .disabled(viewModel.searchKeyDraft.isEmpty)
                }
                .disabled(!viewModel.settings.webAccessEnabled)

                if let url = descriptor.apiKeyHelpURL {
                    Link("Get a key", destination: url)
                        .font(Theme.Typography.caption)
                }
            }

            LabeledContent("Results per search") {
                Stepper(
                    value: Binding(
                        get: { viewModel.settings.maxWebResults },
                        set: { viewModel.settings.maxWebResults = $0 }
                    ),
                    in: 1...10
                ) {
                    Text("\(viewModel.settings.maxWebResults)")
                        .font(Theme.Typography.caption)
                }
            }
            .disabled(!viewModel.settings.webAccessEnabled)

            Text("ScreenMate only calls documented search APIs. It does not crawl or scrape pages.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

struct GeneralSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsGroup("Window") {
            Toggle("Keep the widget above other windows", isOn: Binding(
                get: { viewModel.settings.alwaysOnTop },
                set: { viewModel.settings.alwaysOnTop = $0 }
            ))
            Toggle("Show a menu bar icon", isOn: Binding(
                get: { viewModel.settings.showInMenuBar },
                set: { viewModel.settings.showInMenuBar = $0 }
            ))
            Picker("Appearance", selection: Binding(
                get: { viewModel.settings.theme },
                set: { viewModel.settings.theme = $0 }
            )) {
                ForEach(AppearanceTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
        }

        SettingsGroup("Startup") {
            Toggle("Open ScreenMate when I log in", isOn: Binding(
                get: { viewModel.settings.launchAtLogin },
                set: { viewModel.setLaunchAtLogin($0) }
            ))
        }

        SettingsGroup("Keyboard shortcuts") {
            ShortcutRow(
                title: "Show or hide the panel",
                shortcut: Binding(
                    get: { viewModel.settings.togglePanelShortcut },
                    set: { viewModel.settings.togglePanelShortcut = $0 }
                ),
                isUnavailable: viewModel.unavailableShortcuts.contains(.togglePanel),
                onChange: { viewModel.applyShortcuts() }
            )
            ShortcutRow(
                title: "Start voice input",
                shortcut: Binding(
                    get: { viewModel.settings.voiceInputShortcut },
                    set: { viewModel.settings.voiceInputShortcut = $0 }
                ),
                isUnavailable: viewModel.unavailableShortcuts.contains(.startVoiceInput),
                onChange: { viewModel.applyShortcuts() }
            )
            ShortcutRow(
                title: "Capture a region",
                shortcut: Binding(
                    get: { viewModel.settings.captureRegionShortcut },
                    set: { viewModel.settings.captureRegionShortcut = $0 }
                ),
                isUnavailable: viewModel.unavailableShortcuts.contains(.captureRegion),
                onChange: { viewModel.applyShortcuts() }
            )
        }
    }
}

// MARK: - Reusable pieces

struct SettingsGroup<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.Typography.settingsHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PermissionRow: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// Observed so the row updates the moment the user answers a system prompt.
    @ObservedObject var permissions: PermissionCenter
    let capability: PermissionCapability

    init(viewModel: SettingsViewModel, capability: PermissionCapability) {
        self.viewModel = viewModel
        self.permissions = viewModel.environment.permissions
        self.capability = capability
    }

    private var state: PermissionState { permissions.state(of: capability) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: state.isGranted ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(state.isGranted ? .green : .secondary)
                    .font(.system(size: 11))
                Text(capability.displayName)
                    .font(Theme.Typography.caption)
                Text(state.displayName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if state.canBeRequested {
                    Button("Allow…") { viewModel.requestPermission(capability) }
                        .font(Theme.Typography.caption)
                } else if !state.isGranted {
                    Button("Open System Settings") { viewModel.openPermissionSettings(capability) }
                        .font(Theme.Typography.caption)
                }
            }
            Text(capability.rationale)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
