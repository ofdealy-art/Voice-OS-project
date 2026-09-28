import SwiftUI
import ScreenMateCore

/// Asks the user to approve an action that changes something.
///
/// The prompt is built from the real arguments, so what is approved is the
/// specific action — this URL, this text — not a category of action. Cancel is the
/// default button, and dismissing the sheet counts as declining.
struct ToolConfirmationSheet: View {
    let request: ToolConfirmationRequest
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.yellow)
                Text("ScreenMate wants to \(request.actionVerb)")
                    .font(Theme.Typography.title)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Text(request.prompt)
                    .font(Theme.Typography.message)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            Text("Nothing happens unless you allow it.")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Don't allow", role: .cancel, action: onDecline)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow", action: onApprove)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 360)
        .accessibilityAddTraits(.isModal)
    }
}
