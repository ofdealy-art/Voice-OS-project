import SwiftUI
import ScreenMateCore

/// Shared metrics, colours and type ramp.
///
/// Everything resolves from system materials and semantic colours so the app
/// follows light/dark mode, increased contrast and the user's accent colour
/// without a second code path.
public enum Theme {
    public enum Metrics {
        public static let collapsedSize: CGFloat = 52
        public static let expandedWidth: CGFloat = 380
        public static let expandedHeight: CGFloat = 520
        public static let expandedMinHeight: CGFloat = 340
        public static let cornerRadius: CGFloat = 16
        public static let collapsedCornerRadius: CGFloat = 16
        public static let bubbleCornerRadius: CGFloat = 12
        public static let padding: CGFloat = 12
        public static let tightPadding: CGFloat = 8
        public static let controlSize: CGFloat = 28
    }

    public enum Typography {
        public static let message = Font.system(size: 13)
        public static let messageMeta = Font.system(size: 10, weight: .medium)
        public static let title = Font.system(size: 13, weight: .semibold)
        public static let status = Font.system(size: 11, weight: .medium)
        public static let caption = Font.system(size: 11)
        public static let settingsHeader = Font.system(size: 13, weight: .semibold)
    }

    /// One colour per assistant state, used by the widget's indicator and by
    /// status text, so a colour always means the same thing.
    public static func stateColor(for activity: AssistantActivityStyle) -> Color {
        switch activity {
        case .idle: return .secondary
        case .listening: return .red
        case .screen: return .orange
        case .web: return .teal
        case .working: return .accentColor
        case .speaking: return .purple
        case .error: return .orange
        case .awaitingApproval: return .yellow
        }
    }
}

/// The visual grouping of `AssistantActivity`. Kept separate from the model so
/// the Core type stays free of any notion of colour.
public enum AssistantActivityStyle {
    case idle
    case listening
    case screen
    case web
    case working
    case speaking
    case awaitingApproval
    case error
}

/// A compact icon button matching the app's control metrics.
struct CompactButton: View {
    let systemImage: String
    let help: String
    var role: Role = .normal
    var isActive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    enum Role {
        case normal
        case prominent
        case destructive
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: Theme.Metrics.controlSize, height: Theme.Metrics.controlSize)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var background: AnyShapeStyle {
        if isActive {
            return AnyShapeStyle(tint.opacity(0.22))
        }
        if isHovering && isEnabled {
            return AnyShapeStyle(Color.primary.opacity(0.08))
        }
        return AnyShapeStyle(Color.clear)
    }

    private var foreground: AnyShapeStyle {
        isActive || role != .normal ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary)
    }

    private var tint: Color {
        switch role {
        case .normal: return .accentColor
        case .prominent: return .accentColor
        case .destructive: return .red
        }
    }
}

/// A one-line pill used for status, attachments and citations.
struct InfoPill: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(Theme.Typography.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

extension View {
    /// Applies the user's theme preference to a window's content. `.system`
    /// leaves the scheme alone so the app follows macOS.
    @ViewBuilder
    func themed(_ theme: AppearanceTheme) -> some View {
        switch theme {
        case .system: self
        case .light: self.preferredColorScheme(.light)
        case .dark: self.preferredColorScheme(.dark)
        }
    }
}
