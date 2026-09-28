import AppKit
import SwiftUI
import ScreenMateCore

/// Shows exactly what was captured, before anything is sent.
///
/// This sheet is the promise the privacy copy makes: the user sees the picture,
/// sees what the redactor removed, sees where it will go, and can throw it away.
struct CapturePreviewSheet: View {
    let context: ScreenContext
    let willBeSentTo: String?
    let onAttach: () -> Void
    let onDiscard: () -> Void

    @State private var isShowingExtractedText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .foregroundStyle(.orange)
                Text("Check what ScreenMate captured")
                    .font(Theme.Typography.title)
                Spacer()
            }

            preview

            VStack(alignment: .leading, spacing: 3) {
                Text("\(context.label) · \(context.sourceDescription)")
                    .font(Theme.Typography.caption)
                Text("\(context.pixelWidth) × \(context.pixelHeight) pixels · \(byteDescription)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                if !context.redactionFindings.isEmpty {
                    Label(
                        RedactionFinding.summary(context.redactionFindings),
                        systemImage: "eye.slash"
                    )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.orange)
                    Text("Redaction applies to the text read from the image, not to the picture itself. Check the preview before sending.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                if let destination = willBeSentTo {
                    Label(destination, systemImage: "paperplane")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "This will not be sent — sending screen content is switched off in Settings › Privacy.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.orange)
                }
            }

            if let text = context.extractedText, !text.isEmpty {
                DisclosureGroup(isExpanded: $isShowingExtractedText) {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 96)
                } label: {
                    Text("Text read from this capture on your Mac")
                        .font(Theme.Typography.caption)
                }
            }

            HStack {
                Button("Discard", role: .cancel, action: onDiscard)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Attach and send", action: onAttach)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    @ViewBuilder
    private var preview: some View {
        if let image = NSImage(data: context.imageData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .accessibilityLabel("Preview of the captured \(context.label.lowercased())")
        } else {
            // The bytes exist but could not be decoded for display. Say so rather
            // than silently offering to send something unseen.
            Label(
                "The capture could not be previewed. Discard it rather than sending something you cannot see.",
                systemImage: "exclamationmark.triangle"
            )
            .font(Theme.Typography.caption)
            .foregroundStyle(.orange)
        }
    }

    private var byteDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(context.byteCount))
    }
}
