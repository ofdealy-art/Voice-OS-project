import AppKit
import SwiftUI
import ScreenMateCore

/// The root of the floating panel: collapsed puck or full panel, plus every sheet.
public struct AssistantRootView: View {
    @ObservedObject var model: AssistantViewModel
    // Observed explicitly: SwiftUI redraws only for the objects a view watches.
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var screen: ScreenAwarenessController
    @ObservedObject var toolConfirmations: ToolConfirmationCenter

    public init(model: AssistantViewModel) {
        self.model = model
        self.environment = model.environment
        self.screen = model.screen
        self.toolConfirmations = model.environment.toolConfirmations
    }

    public var body: some View {
        Group {
            if model.isPanelExpanded {
                ExpandedPanelView(model: model)
            } else {
                CollapsedWidgetView(model: model)
            }
        }
        .themed(environment.settings.theme)
        // Escape collapses the panel, or cancels whatever is in flight.
        .onExitCommand { handleEscape() }
        .sheet(isPresented: previewBinding) {
            if let context = screen.previewContext {
                CapturePreviewSheet(
                    context: context,
                    willBeSentTo: destinationDescription,
                    onAttach: { screen.approvePreview() },
                    onDiscard: { screen.discard() }
                )
                .themed(environment.settings.theme)
            }
        }
        .sheet(isPresented: confirmationBinding) {
            if let request = toolConfirmations.pending {
                ToolConfirmationSheet(
                    request: request,
                    onApprove: { toolConfirmations.approve() },
                    onDecline: { toolConfirmations.decline() }
                )
                .themed(environment.settings.theme)
            }
        }
        .sheet(isPresented: $model.isShowingOnboarding) {
            OnboardingView(model: model)
                .themed(environment.settings.theme)
        }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsView(viewModel: SettingsViewModel(environment: model.environment))
                .themed(environment.settings.theme)
        }
    }

    /// Dismissing the sheet by any route counts as declining, which is the safe
    /// default for an action that would change something.
    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { toolConfirmations.pending != nil },
            set: { isPresented in
                if !isPresented { toolConfirmations.decline() }
            }
        )
    }

    private var previewBinding: Binding<Bool> {
        Binding(
            get: { screen.previewContext != nil },
            set: { isPresented in
                if !isPresented { screen.discard() }
            }
        )
    }

    private var destinationDescription: String? {
        guard environment.settings.mayShareScreenWithProvider else { return nil }
        let name = environment.providerCatalog
            .descriptor(for: environment.settings.chatProviderID)?
            .displayName ?? environment.settings.chatProviderID
        return "Will be sent to \(name) when you send your message."
    }

    private func handleEscape() {
        if toolConfirmations.pending != nil {
            toolConfirmations.decline()
            return
        }
        if screen.previewContext != nil {
            screen.discard()
            return
        }
        if model.voice.isListening {
            model.voice.cancel()
            return
        }
        if model.isBusy || model.activity == .speaking {
            model.stopGeneration()
            return
        }
        model.isPanelExpanded = false
    }
}
