import AppKit
import Combine
import ScreenMateCore

/// The menu bar item.
///
/// A background app with no Dock icon needs one visible, permanent way back in,
/// and the icon doubles as a status light: it changes while the microphone is open
/// or the screen is being read.
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private let model: AssistantViewModel
    private let onToggle: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(model: AssistantViewModel, onToggle: @escaping () -> Void) {
        self.model = model
        self.onToggle = onToggle

        model.environment.$settings
            .map(\.showInMenuBar)
            .removeDuplicates()
            .sink { [weak self] shouldShow in
                if shouldShow { self?.install() } else { self?.remove() }
            }
            .store(in: &cancellables)

        model.activityPublisher
            .sink { [weak self] activity in
                self?.updateIcon(for: activity)
            }
            .store(in: &cancellables)

        if model.environment.settings.showInMenuBar { install() }
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "ScreenMate"
        )
        item.button?.toolTip = "ScreenMate"
        item.menu = buildMenu()
        statusItem = item
        updateIcon(for: model.activity)
    }

    private func remove() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func updateIcon(for activity: AssistantActivity) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if activity.isCapturingAudio {
            symbol = "mic.fill"
        } else if activity.isReadingScreen {
            symbol = "eye.fill"
        } else if activity.isBusy {
            symbol = "sparkles"
        } else {
            symbol = "sparkles"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenMate")
        button.toolTip = "ScreenMate — \(activity.shortLabel)"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = menuDelegate
        menu.addItem(
            withTitle: "Show ScreenMate",
            action: #selector(MenuActions.toggle),
            keyEquivalent: ""
        ).target = actions
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Start voice input",
            action: #selector(MenuActions.startVoice),
            keyEquivalent: ""
        ).target = actions
        menu.addItem(
            withTitle: "Capture a region…",
            action: #selector(MenuActions.captureRegion),
            keyEquivalent: ""
        ).target = actions
        menu.addItem(.separator())
        screenAwarenessItem = menu.addItem(
            withTitle: "Screen awareness",
            action: #selector(MenuActions.toggleScreenAwareness),
            keyEquivalent: ""
        )
        screenAwarenessItem?.target = actions
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(MenuActions.openSettings),
            keyEquivalent: ","
        ).target = actions
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit ScreenMate",
            action: #selector(MenuActions.quit),
            keyEquivalent: "q"
        ).target = actions
        return menu
    }

    private var screenAwarenessItem: NSMenuItem?

    private lazy var actions = MenuActions(
        toggleHandler: { [weak self] in self?.onToggle() },
        startVoiceHandler: { [weak self] in self?.model.voice.toggle() },
        captureRegionHandler: { [weak self] in self?.model.captureScreen(scope: .selectedRegion) },
        toggleScreenAwarenessHandler: { [weak self] in self?.model.toggleScreenAwareness() },
        openSettingsHandler: { [weak self] in
            self?.onToggle()
            self?.model.isShowingSettings = true
        }
    )

    private lazy var menuDelegate = MenuRefresher { [weak self] in
        guard let self else { return }
        self.screenAwarenessItem?.state =
            self.model.environment.settings.screenAwarenessEnabled ? .on : .off
    }
}

/// Target for the menu items. `NSMenu` needs an `NSObject` with selectors.
@MainActor
private final class MenuActions: NSObject {
    private let toggleHandler: () -> Void
    private let startVoiceHandler: () -> Void
    private let captureRegionHandler: () -> Void
    private let toggleScreenAwarenessHandler: () -> Void
    private let openSettingsHandler: () -> Void

    init(
        toggleHandler: @escaping () -> Void,
        startVoiceHandler: @escaping () -> Void,
        captureRegionHandler: @escaping () -> Void,
        toggleScreenAwarenessHandler: @escaping () -> Void,
        openSettingsHandler: @escaping () -> Void
    ) {
        self.toggleHandler = toggleHandler
        self.startVoiceHandler = startVoiceHandler
        self.captureRegionHandler = captureRegionHandler
        self.toggleScreenAwarenessHandler = toggleScreenAwarenessHandler
        self.openSettingsHandler = openSettingsHandler
        super.init()
    }

    @objc func toggle() { toggleHandler() }
    @objc func startVoice() { startVoiceHandler() }
    @objc func captureRegion() { captureRegionHandler() }
    @objc func toggleScreenAwareness() { toggleScreenAwarenessHandler() }
    @objc func openSettings() { openSettingsHandler() }
    @objc func quit() { NSApp.terminate(nil) }
}

/// Refreshes checkmarks each time the menu opens.
///
/// Not main-actor isolated, because `NSMenuDelegate` makes no such guarantee; the
/// stored closure is isolated instead and invoked after a hop.
private final class MenuRefresher: NSObject, NSMenuDelegate {
    private let onOpen: @MainActor () -> Void

    init(onOpen: @escaping @MainActor () -> Void) {
        self.onOpen = onOpen
        super.init()
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in onOpen() }
    }
}
