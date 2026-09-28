import AppKit
import ScreenMateCore

/// Full-screen drag-to-select overlay, one window per display.
///
/// Presented over every screen so a selection can start on one monitor and end
/// on another. Escape or a right-click cancels; a drag smaller than a few points
/// is treated as a mis-click and also cancels, rather than sending a sliver of
/// screen to a model.
@MainActor
public final class RegionSelectionController {
    private var windows: [RegionSelectionWindow] = []
    private var completion: ((ScreenRegion?) -> Void)?

    public init() {}

    public var isPresenting: Bool { !windows.isEmpty }

    /// Shows the overlay. The completion receives the selected region in
    /// CoreGraphics global coordinates, or `nil` if the user cancelled.
    public func present(completion: @escaping (ScreenRegion?) -> Void) {
        dismiss()
        self.completion = completion

        for screen in NSScreen.screens {
            let window = RegionSelectionWindow(screen: screen)
            window.onSelection = { [weak self] rect in
                self?.finish(with: rect)
            }
            window.onCancel = { [weak self] in
                self?.finish(with: nil)
            }
            window.orderFrontRegardless()
            windows.append(window)
        }
        // Let the overlay take key input so Escape works without the user
        // having to click first.
        windows.first?.makeKey()
        NSCursor.crosshair.push()
    }

    public func dismiss() {
        guard !windows.isEmpty else { return }
        NSCursor.pop()
        for window in windows {
            window.onSelection = nil
            window.onCancel = nil
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func finish(with rect: CGRect?) {
        let handler = completion
        completion = nil
        dismiss()

        guard let rect else {
            handler?(nil)
            return
        }
        let region = ScreenRegion(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
        handler?(region.isUsable ? region : nil)
    }
}

/// One borderless window covering a single display.
final class RegionSelectionWindow: NSWindow {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let selectionView = RegionSelectionView()
    private let hostScreen: NSScreen

    init(screen: NSScreen) {
        self.hostScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Above everything, including other apps' full-screen windows.
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)

        selectionView.frame = CGRect(origin: .zero, size: screen.frame.size)
        selectionView.autoresizingMask = [.width, .height]
        selectionView.onCommit = { [weak self] localRect in
            guard let self else { return }
            self.onSelection?(self.globalRect(from: localRect))
        }
        selectionView.onCancel = { [weak self] in self?.onCancel?() }
        contentView = selectionView

        selectionView.setAccessibilityLabel(
            "Screen region selector. Drag to choose the area to analyse, or press Escape to cancel."
        )
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape. Handled here too, because a borderless window does not
        // always route it through `cancelOperation`.
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    /// Converts a rect in this window's view coordinates (origin bottom-left) to
    /// global CoreGraphics coordinates (origin top-left of the primary display).
    private func globalRect(from local: CGRect) -> CGRect {
        let screenRect = CGRect(
            x: hostScreen.frame.minX + local.minX,
            y: hostScreen.frame.minY + local.minY,
            width: local.width,
            height: local.height
        )
        guard let primary = NSScreen.screens.first else { return screenRect }
        return CGRect(
            x: screenRect.minX,
            y: primary.frame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
    }
}

/// Draws the dimmed backdrop and the selection rectangle.
final class RegionSelectionView: NSView {
    var onCommit: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var anchor: CGPoint?
    private var current: CGRect = .zero

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard current.width > 0, current.height > 0 else { return }

        // Punch the selection out of the dim layer so the user sees exactly what
        // will be captured.
        NSColor.clear.setFill()
        current.fill(using: .copy)

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: current.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        border.stroke()

        drawSizeLabel()
    }

    private func drawSizeLabel() {
        let text = "\(Int(current.width)) × \(Int(current.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let padding: CGFloat = 5
        var origin = CGPoint(x: current.minX, y: current.maxY + padding)
        if origin.y + size.height + padding > bounds.maxY {
            origin.y = current.minY - size.height - padding * 2
        }
        let box = CGRect(
            x: origin.x,
            y: origin.y,
            width: size.width + padding * 2,
            height: size.height + padding
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil
            current = .zero
            needsDisplay = true
        }
        guard current.width >= 8, current.height >= 8 else {
            // A click rather than a drag: treat as cancel, not as a 1×1 capture.
            onCancel?()
            return
        }
        onCommit?(current)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }
}
