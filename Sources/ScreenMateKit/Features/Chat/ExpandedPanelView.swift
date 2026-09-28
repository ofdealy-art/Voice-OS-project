import AppKit
import SwiftUI
import ScreenMateCore

/// The full assistant panel.
struct ExpandedPanelView: View {
    @ObservedObject var model: AssistantViewModel
    // Observed explicitly: SwiftUI redraws only for the objects a view watches.
    @ObservedObject var environment: AppEnvironment

    init(model: AssistantViewModel) {
        self.model = model
        self.environment = model.environment
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let disclosure = model.lastScreenDisclosure {
                disclosureStrip(disclosure)
            }

            if let banner = model.banner {
                BannerView(banner: banner, model: model)
            }

            transcript

            Divider()
            statusRow
            ComposerView(model: model)
                .padding(.horizontal, Theme.Metrics.padding)
                .padding(.vertical, Theme.Metrics.tightPadding)
        }
        .frame(
            width: Theme.Metrics.expandedWidth,
            height: Theme.Metrics.expandedHeight
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            StateIndicator(style: model.activityStyle, level: level, diameter: 16)

            Text("ScreenMate")
                .font(Theme.Typography.title)

            Spacer(minLength: 0)

            CompactButton(
                systemImage: environment.settings.screenAwarenessEnabled ? "eye" : "eye.slash",
                help: environment.settings.screenAwarenessEnabled
                    ? "Screen awareness is on — click to pause"
                    : "Screen awareness is off — click to turn on",
                isActive: environment.settings.screenAwarenessEnabled
            ) {
                model.toggleScreenAwareness()
            }

            CompactButton(
                systemImage: environment.settings.speakResponses ? "speaker.wave.2" : "speaker.slash",
                help: environment.settings.speakResponses
                    ? "Replies are spoken — click to mute"
                    : "Replies are silent — click to speak them",
                isActive: environment.settings.speakResponses
            ) {
                environment.settings.speakResponses.toggle()
                if !environment.settings.speakResponses { model.stopSpeaking() }
            }

            Menu {
                Button("New conversation") { model.startNewConversation() }
                Button("Clear conversation") { model.clearConversation() }
                Divider()
                Menu("Export conversation") {
                    ForEach(ConversationExporter.Format.allCases) { format in
                        Button(format.displayName) { model.exportConversation(as: format) }
                    }
                }
                Divider()
                Button("Settings…") { model.isShowingSettings = true }
                Button("Privacy and permissions…") {
                    model.isShowingOnboarding = true
                }
                Divider()
                Button("Quit ScreenMate") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Theme.Metrics.controlSize, height: Theme.Metrics.controlSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Theme.Metrics.controlSize)
            .help("More actions")
            .accessibilityLabel("More actions")

            CompactButton(systemImage: "minus", help: "Collapse to the widget (Esc)") {
                model.isPanelExpanded = false
            }
        }
        .padding(.horizontal, Theme.Metrics.tightPadding)
        .padding(.vertical, 6)
    }

    private var level: Float {
        if case .listening(let level) = model.activity { return level }
        return 0
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.conversation.messages.isEmpty {
                        EmptyStateView(model: model)
                            .padding(.top, 28)
                    }
                    ForEach(model.conversation.messages) { message in
                        MessageRowView(
                            message: message,
                            onSpeak: { model.speakAgain($0) },
                            onCopy: { copy($0) },
                            onRetry: nil
                        )
                        .id(message.id)
                    }
                    // Anchor so the view can scroll past the last bubble.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, Theme.Metrics.padding)
                .padding(.vertical, Theme.Metrics.tightPadding)
            }
            .onChange(of: model.conversation.messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: model.conversation.messages.last?.text) { _ in
                scrollToBottom(proxy)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private static let bottomAnchor = "screenmate.transcript.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private func copy(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: 6) {
            Text(model.activity.shortLabel)
                .font(Theme.Typography.status)
                .foregroundStyle(model.activity.isBusy ? Theme.stateColor(for: model.activityStyle) : .secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if !environment.settings.webAccessEnabled {
                InfoPill(systemImage: "globe.badge.chevron.backward", text: "Web off")
            }
            if !environment.settings.screenAwarenessEnabled {
                InfoPill(systemImage: "eye.slash", text: "Screen off")
            }
            if environment.settings.chatProviderID == DemoChatProvider.providerID {
                InfoPill(systemImage: "testtube.2", text: "Demo provider", tint: .purple)
            }
        }
        .padding(.horizontal, Theme.Metrics.padding)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.activity.accessibilityAnnouncement)
    }

    private func disclosureStrip(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "paperplane")
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(Theme.Typography.caption)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.padding)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.1))
        .foregroundStyle(.secondary)
    }
}

/// Shown before the first message: what ScreenMate can do, in the user's words.
struct EmptyStateView: View {
    @ObservedObject var model: AssistantViewModel
    @ObservedObject var environment: AppEnvironment

    init(model: AssistantViewModel) {
        self.model = model
        self.environment = model.environment
    }

    private let examples = [
        "What am I looking at?",
        "Explain this error.",
        "Summarise this page.",
        "Rewrite this professionally.",
    ]

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)

            Text("Ask a question, or hold the microphone.")
                .font(Theme.Typography.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                ForEach(examples, id: \.self) { example in
                    Button(example) {
                        model.composerText = example
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }

            if !environment.settings.screenAwarenessEnabled {
                Text("Screen awareness is off, so ScreenMate cannot see your screen yet.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The error / info strip under the header.
struct BannerView: View {
    let banner: AssistantViewModel.BannerMessage
    @ObservedObject var model: AssistantViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.message)
                    .font(Theme.Typography.caption)
                if let nextStep = banner.nextStep {
                    Text(nextStep)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                if let anchor = banner.settingsAnchor {
                    Button("Open \(anchor.title) settings") {
                        model.isShowingSettings = true
                    }
                    .buttonStyle(.link)
                    .font(Theme.Typography.caption)
                }
            }

            Spacer(minLength: 0)

            CompactButton(systemImage: "xmark", help: "Dismiss") {
                model.dismissBanner()
            }
        }
        .padding(.horizontal, Theme.Metrics.padding)
        .padding(.vertical, 7)
        .background(tint.opacity(0.1))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch banner.kind {
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .error: return .orange
        case .info: return .accentColor
        case .success: return .green
        }
    }
}
