import Foundation
import ServiceManagement

enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp

        if enabled {
            guard service.status != .enabled else {
                return
            }
            try service.register()
            return
        }

        guard service.status == .enabled || service.status == .requiresApproval else {
            return
        }
        try service.unregister()
    }
}
