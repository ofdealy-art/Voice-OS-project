import Foundation
import ScreenMateCore
import ServiceManagement

/// Registers ScreenMate as a login item.
///
/// `SMAppService.mainApp` is macOS 13+, needs no helper bundle, and shows up in
/// System Settings › General › Login Items where the user can turn it off — which
/// is the behaviour a background app should have.
public enum LoginItemController {
    public static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw AppError.storageFailure(detail: "login item could not be updated: \(error.localizedDescription)")
        }
    }

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
