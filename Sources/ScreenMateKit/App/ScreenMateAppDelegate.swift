import AppKit
import ScreenMateCore

/// Wires the app together at launch and tears it down cleanly on quit.
///
/// ScreenMate runs as an accessory app: no Dock icon, no main window, just the
/// floating panel and a menu bar item. That is `LSUIElement` in Info.plist plus
/// `.accessory` here.
@MainActor
public final class ScreenMateAppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var model: AssistantViewModel?
    private var panelController: FloatingPanelController?
    private var menuBarController: MenuBarController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // macOS 13 is the floor: ScreenCaptureKit stills, SMAppService and the
        // SwiftUI APIs this app uses all start there.
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        ) else {
            presentUnsupportedOSAlert()
            return
        }

        let environment = AppEnvironment()
        let model = AssistantViewModel(environment: environment)
        let panelController = FloatingPanelController(model: model)

        self.environment = environment
        self.model = model
        self.panelController = panelController
        self.menuBarController = MenuBarController(model: model) { [weak panelController] in
            panelController?.presentExpanded()
        }

        environment.hotKeys.onHotKey { [weak self] action in
            self?.handle(action)
        }
        let unavailable = environment.hotKeys.register(settings: environment.settings)
        if !unavailable.isEmpty {
            model.presentInfo(
                message: "Some keyboard shortcuts are already used by another app.",
                nextStep: "Pick different combinations in Settings › General.",
                anchor: .general
            )
        }

        panelController.show()

        // First run opens straight into the privacy walkthrough, expanded, so the
        // permissions conversation happens before anything is captured.
        if !environment.settings.hasCompletedOnboarding {
            panelController.presentExpanded()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        environment?.handleTermination()
    }

    /// The app has no windows to restore; clicking the Dock icon (if one is ever
    /// shown) or reopening brings the panel forward instead.
    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        panelController?.presentExpanded()
        return true
    }

    private func handle(_ action: HotKeyAction) {
        guard let model, let panelController else { return }
        switch action {
        case .togglePanel:
            if panelController.isVisible && model.isPanelExpanded {
                model.isPanelExpanded = false
            } else {
                panelController.presentExpanded()
            }
        case .startVoiceInput:
            panelController.presentExpanded()
            model.voice.toggle()
        case .captureRegion:
            panelController.show()
            model.captureScreen(scope: .selectedRegion)
        }
    }

    private func presentUnsupportedOSAlert() {
        let error = AppError.unsupportedOSVersion(required: "macOS 13 (Ventura)")
        let alert = NSAlert()
        alert.messageText = error.errorDescription ?? "Unsupported macOS version"
        alert.informativeText = error.recoverySuggestion ?? ""
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
