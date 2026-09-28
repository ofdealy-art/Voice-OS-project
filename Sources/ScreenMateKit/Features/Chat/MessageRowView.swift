import SwiftUI
import ScreenMateCore

/// One message in the transcript.
///
/// User and assistant messages are distinguished by alignment, background and a
/// label — not by colour alone, so the difference survives high-contrast mode and
/// colour-blindness. Attachments, tool runs, sources and failures each get their
/// own visible treatment.
struct MessageRowView: View {
    let message: ChatMessage
    let onSpeak: (ChatMessage) -> Void
    let onCopy: (ChatMessage) -> Void
    let onRetry: (() -> Void)?

    @State private var isHovering = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 5) {
                if isUser { Spacer(minLength: 0) }
                Text(speakerLabel)
                    .font(Theme.Typography.messageMeta)
                    .foregroundStyle(.secondary)
                if message.source == .voice {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Spoken")
                }
                if !isUser { Spacer(minLength: 0) }
            }

            if !message.attachments.isEmpty {
                VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                    ForEach(message.attachments) { attachment in
                        InfoPill(
                            systemImage: "rectangle.dashed.badge.record",
                            text: attachmentText(attachment),
                            tint: .orange
                        )
                    }
                }
            }

            if let failure = message.failure {
                failureView(failure)
            } else {
                bubble
            }

            if !message.toolInvocations.isEmpty {
                VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                    ForEach(message.toolInvocations) { invocation in
                        InfoPill(
                            systemImage: icon(for: invocation.outcome),
                            text: invocation.summary,
                            tint: tint(for: invocation.outcome)
                        )
                    }
                }
            }

            if !message.citations.isEmpty {
                citationsView
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerLabel): \(message.failure?.message ?? message.text)")
    }

    private var bubble: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if isUser { Spacer(minLength: 24) }

            Text(displayText)
                .font(Theme.Typography.message)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    isUser ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.bubbleCornerRadius, style: .continuous)
                )
                .overlay(alignment: .bottomTrailing) {
                    if message.isStreaming {
                        StreamingCaret()
                            .padding(.trailing, 6)
                            .padding(.bottom, 7)
                    }
                }

            if !isUser {
                actions
                    .opacity(isHovering ? 1 : 0)
            }
            if !isUser { Spacer(minLength: 24) }
        }
    }

    private var displayText: String {
        if message.text.isEmpty && message.isStreaming { return " " }
        return message.text
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 2) {
            CompactButton(systemImage: "doc.on.doc", help: "Copy this reply") { onCopy(message) }
            CompactButton(systemImage: "speaker.wave.2", help: "Read this reply aloud") { onSpeak(message) }
        }
    }

    private func failureView(_ failure: MessageFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                Text(failure.message)
                    .font(Theme.Typography.message)
            }
            if let nextStep = failure.nextStep {
                Text(nextStep)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if failure.isRetryable, let onRetry {
                Button("Try again", action: onRetry)
                    .buttonStyle(.link)
                    .font(Theme.Typography.caption)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.Metrics.bubbleCornerRadius, style: .continuous)
        )
    }

    private var citationsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources")
                .font(Theme.Typography.messageMeta)
                .foregroundStyle(.secondary)
            ForEach(message.citations.indices, id: \.self) { index in
                let citation = message.citations[index]
                Link(destination: citation.url) {
                    HStack(spacing: 4) {
                        Text("\(index + 1).")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(citation.title)
                            .font(Theme.Typography.caption)
                            .lineLimit(1)
                        Text(citation.url.host ?? "")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(citation.url.absoluteString)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speakerLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "ScreenMate"
        case .system: return "System"
        }
    }

    private func attachmentText(_ attachment: MessageAttachment) -> String {
        var text = attachment.label
        if let source = attachment.sourceDescription { text += " · \(source)" }
        if attachment.redactionSummary != nil { text += " · redacted" }
        return text
    }

    private func icon(for outcome: ToolInvocationRecord.Outcome) -> String {
        switch outcome {
        case .succeeded: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .declinedByUser: return "hand.raised"
        case .awaitingConfirmation: return "clock"
        }
    }

    private func tint(for outcome: ToolInvocationRecord.Outcome) -> Color {
        switch outcome {
        case .succeeded: return .teal
        case .failed: return .orange
        case .declinedByUser: return .secondary
        case .awaitingConfirmation: return .yellow
        }
    }
}

/// A blinking block cursor while tokens are arriving.
struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .frame(width: 5, height: 11)
            .foregroundStyle(.secondary)
            .opacity(isVisible ? 1 : 0.15)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever()) {
                    isVisible = false
                }
            }
            .accessibilityHidden(true)
    }
}
