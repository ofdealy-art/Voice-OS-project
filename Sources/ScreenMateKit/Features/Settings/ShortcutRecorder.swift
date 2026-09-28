import AppKit
import Carbon.HIToolbox
import SwiftUI
import ScreenMateCore

/// A row that records a global shortcut.
struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: KeyboardShortcut
    let isUnavailable: Bool
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.Typography.caption)
            Spacer(minLength: 8)
            if isUnavailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10))
                    .help("Another app already uses this shortcut.")
            }
            ShortcutRecorderView(shortcut: $shortcut, onChange: onChange)
                .frame(width: 110, height: 22)
        }
    }
}

/// An `NSView` that shows the current shortcut and records a new one when focused.
///
/// Written against AppKit because SwiftUI has no way to observe a raw key event
/// with modifiers without also consuming it for the whole window.
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut
    let onChange: () -> Void

    func makeNSView(context: Context) -> RecorderControl {
        let control = RecorderControl()
        control.onRecord = { recorded in
            shortcut = recorded
            onChange()
        }
        control.shortcut = shortcut
        return control
    }

    func updateNSView(_ nsView: RecorderControl, context: Context) {
        nsView.shortcut = shortcut
    }

    final class RecorderControl: NSView {
        var onRecord: ((KeyboardShortcut) -> Void)?

        var shortcut: KeyboardShortcut = .defaultToggle {
            didSet { needsDisplay = true }
        }

        private var isRecording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Keyboard shortcut")
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.textBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()

            let text = isRecording ? "Press keys…" : shortcut.displayString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
            setAccessibilityValue(shortcut.displayString)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            // Escape abandons recording and keeps the existing shortcut.
            if event.keyCode == 53 {
                isRecording = false
                window?.makeFirstResponder(nil)
                return
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])
            // A global shortcut without a modifier would swallow ordinary typing
            // in every app, so require at least one.
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return
            }

            let recorded = KeyboardShortcut(
                keyCode: UInt32(event.keyCode),
                modifierFlags: modifiers.rawValue,
                displayString: Self.displayString(keyCode: event.keyCode, modifiers: modifiers)
            )
            shortcut = recorded
            isRecording = false
            window?.makeFirstResponder(nil)
            onRecord?(recorded)
        }

        /// "⌥⌘Space"
        static func displayString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
            var glyphs = ""
            if modifiers.contains(.control) { glyphs += "⌃" }
            if modifiers.contains(.option) { glyphs += "⌥" }
            if modifiers.contains(.shift) { glyphs += "⇧" }
            if modifiers.contains(.command) { glyphs += "⌘" }
            return glyphs + keyName(for: keyCode)
        }

        static func keyName(for keyCode: UInt16) -> String {
            // Only the keys whose names are not their characters need a table.
            let named: [UInt16: String] = [
                UInt16(kVK_Space): "Space",
                UInt16(kVK_Return): "↩",
                UInt16(kVK_Tab): "⇥",
                UInt16(kVK_Delete): "⌫",
                UInt16(kVK_Escape): "⎋",
                UInt16(kVK_LeftArrow): "←",
                UInt16(kVK_RightArrow): "→",
                UInt16(kVK_UpArrow): "↑",
                UInt16(kVK_DownArrow): "↓",
                UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
                UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
                UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
                UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            ]
            if let name = named[keyCode] { return name }
            return characterName(for: keyCode) ?? "Key \(keyCode)"
        }

        /// Asks the current keyboard layout what this key produces, so the label is
        /// right on a non-US layout.
        static func characterName(for keyCode: UInt16) -> String? {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                return nil
            }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let capacity = characters.count
            var length = 0

            let status = data.withUnsafeBytes { buffer -> OSStatus in
                guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                    return OSStatus(paramErr)
                }
                return UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    capacity,
                    &length,
                    &characters
                )
            }
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}
