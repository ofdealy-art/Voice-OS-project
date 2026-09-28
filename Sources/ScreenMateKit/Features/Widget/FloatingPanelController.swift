import AppKit
import Combine
import SwiftUI
import ScreenMateCore

/// A borderless, non-activating panel that floats over other apps.
///
/// `NSPanel` with `.nonactivatingPanel` is what makes the widget usable without
/// stealing focus from whatever the user is working in: clicking it does not
/// switch apps, but the panel can still become key so the text field accepts
/// typing. `canJoinAllSpaces` plus `fullScreenAuxiliary` keeps it visible across
/// Spaces and over other apps' full-screen windows.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isOpaque = false
        backgroundColor = .clear
        // SwiftUI draws the shadow so it follows the rounded corners.
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
    }

    /// Required so the text field can take keystrokes. Combined with
    /// `.nonactivatingPanel`, this gives keyboard focus without app activation.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel, its size, its position and its level.
@MainActor
final class FloatingPanelController {
    private let panel: FloatingPanel
    private let model: AssistantViewModel
    private var cancellables: Set<AnyCancellable> = []
    /// Suppresses position saving while the controller itself is moving the panel.
    private var isAdjustingFrame = false

    init(model: AssistantViewModel) {
        self.model = model
        let size = CGSize(
            width: Theme.Metrics.collapsedSize,
            height: Theme.Metrics.collapsedSize
        )
        self.panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: size))

        let hosting = NSHostingView(rootView: AssistantRootView(model: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)

        observe()
        applyLevel()
        restorePosition()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    func toggleVisibility() {
        if panel.isVisible {
            hide()
        } else {
            show()
            if model.isPanelExpanded { panel.makeKey() }
        }
    }

    /// Opens the panel expanded and focused — what a global shortcut should do.
    func presentExpanded() {
        model.isPanelExpanded = true
        show()
        panel.makeKey()
    }

    // MARK: - Observation

    private func observe() {
        model.$isPanelExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.resize(expanded: expanded)
            }
            .store(in: &cancellables)

        model.environment.$settings
            .map(\.alwaysOnTop)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyLevel()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in
                self?.savePosition()
            }
            .store(in: &cancellables)

        // A display being added, removed or rearranged can leave the panel
        // off-screen; pull it back into view.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.constrainToVisibleFrame()
            }
            .store(in: &cancellables)
    }

    private func applyLevel() {
        // `.floating` sits above normal windows; `.normal` lets them cover it.
        panel.level = model.environment.settings.alwaysOnTop ? .floating : .normal
    }

    private func resize(expanded: Bool) {
        let size = expanded
            ? CGSize(width: Theme.Metrics.expandedWidth, height: Theme.Metrics.expandedHeight)
            : CGSize(width: Theme.Metrics.collapsedSize, height: Theme.Metrics.collapsedSize)

        // Grow from the current top-left so the widget does not appear to jump.
        let currentFrame = panel.frame
        var origin = CGPoint(x: currentFrame.minX, y: currentFrame.maxY - size.height)

        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }

        isAdjustingFrame = true
        panel.setFrame(CGRect(origin: origin, size: size), display: true, animate: false)
        isAdjustingFrame = false

        if expanded {
            panel.makeKey()
        }
    }

    private func restorePosition() {
        let settings = model.environment.settings
        guard let x = settings.widgetOriginX, let y = settings.widgetOriginY else {
            positionAtDefaultCorner()
            return
        }
        isAdjustingFrame = true
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        isAdjustingFrame = false
        constrainToVisibleFrame()
    }

    /// Bottom-right of the main screen, clear of the Dock.
    private func positionAtDefaultCorner() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.maxX - Theme.Metrics.collapsedSize - 24,
            y: visible.minY + 24
        )
        isAdjustingFrame = true
        panel.setFrameOrigin(origin)
        isAdjustingFrame = false
        savePosition()
    }

    private func savePosition() {
        guard !isAdjustingFrame else { return }
        let origin = panel.frame.origin
        model.environment.settings.widgetOriginX = origin.x
        model.environment.settings.widgetOriginY = origin.y
    }

    /// Keeps at least part of the panel reachable after a display change.
    private func constrainToVisibleFrame() {
        let frame = panel.frame
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let isOnScreen = screens.contains { $0.visibleFrame.intersects(frame) }
        guard !isOnScreen else { return }

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
            y: min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        )
        isAdjustingFrame = true
        panel.setFrameOrigin(origin)
        isAdjustingFrame = false
        savePosition()
    }
}
