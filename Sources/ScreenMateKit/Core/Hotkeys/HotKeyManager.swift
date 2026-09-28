import AppKit
import Carbon.HIToolbox
import ScreenMateCore

public enum HotKeyAction: UInt32, CaseIterable, Sendable {
    case togglePanel = 1
    case startVoiceInput = 2
    case captureRegion = 3
}

/// Registers system-wide keyboard shortcuts.
///
/// Carbon's `RegisterEventHotKey` rather than `NSEvent` global monitors: it works
/// without Accessibility permission, which keeps the shortcut available to users
/// who decline that prompt.
@MainActor
public final class HotKeyManager {
    private struct Registration {
        let action: HotKeyAction
        let reference: EventHotKeyRef
    }

    private var registrations: [Registration] = []
    private var eventHandler: EventHandlerRef?
    private var handler: ((HotKeyAction) -> Void)?

    public init() {}

    // No `deinit`: a `@MainActor` class's `deinit` is non-isolated and cannot
    // reach isolated state. The manager lives for the whole process, and
    // `unregisterAll()` is the explicit teardown for anything that needs it.

    public func onHotKey(_ handler: @escaping (HotKeyAction) -> Void) {
        self.handler = handler
    }

    /// Replaces all registrations with the shortcuts in `settings`.
    ///
    /// Returns the actions that could not be registered — normally because
    /// another app already owns the combination. The caller surfaces that in
    /// Settings so the user can pick a different one rather than wondering why
    /// nothing happens.
    @discardableResult
    public func register(settings: AppSettings) -> [HotKeyAction] {
        unregisterAll()
        installEventHandlerIfNeeded()

        var failures: [HotKeyAction] = []
        let shortcuts: [(HotKeyAction, KeyboardShortcut)] = [
            (.togglePanel, settings.togglePanelShortcut),
            (.startVoiceInput, settings.voiceInputShortcut),
            (.captureRegion, settings.captureRegionShortcut),
        ]

        for (action, shortcut) in shortcuts {
            guard register(action: action, shortcut: shortcut) else {
                failures.append(action)
                continue
            }
        }
        return failures
    }

    public func unregisterAll() {
        for registration in registrations {
            UnregisterEventHotKey(registration.reference)
        }
        registrations.removeAll()
    }

    private func register(action: HotKeyAction, shortcut: KeyboardShortcut) -> Bool {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(from: shortcut.modifierFlags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        registrations.append(Registration(action: action, reference: reference))
        return true
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            guard let action = HotKeyAction(rawValue: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon calls back on the main thread, but hop explicitly so the
            // compiler can see the isolation.
            Task { @MainActor in manager.handler?(action) }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    /// Four-character code identifying ScreenMate's hot keys.
    static let signature: OSType = {
        let characters = Array("SCMT".utf8)
        return characters.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()

    /// Translates `NSEvent.ModifierFlags` raw bits to Carbon's modifier mask.
    static func carbonModifiers(from flags: UInt) -> UInt32 {
        let modifiers = NSEvent.ModifierFlags(rawValue: flags)
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
