import AppKit
import ScreenMateKit

/// Entry point.
///
/// A plain `NSApplication` lifecycle rather than SwiftUI's `App` protocol: the
/// product is a borderless, non-activating `NSPanel` that must not steal focus,
/// and that is far easier to get right without `WindowGroup` in the way. The
/// delegate builds the dependency graph and the panel.
///
/// `main()` is main-actor isolated because everything it touches — `NSApplication`,
/// the delegate — is.
@main
enum ScreenMateMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = ScreenMateAppDelegate()
        application.delegate = delegate
        // The delegate is not retained by `NSApplication`, so hold it for the
        // lifetime of the process.
        retainedDelegate = delegate
        application.run()
    }

    @MainActor
    private static var retainedDelegate: ScreenMateAppDelegate?
}
