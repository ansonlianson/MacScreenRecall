import Foundation
import ServiceManagement

@MainActor
enum LaunchAgentService {
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func setLaunchAtLogin(_ enabled: Bool) -> (Bool, String?) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return (true, nil) }
                try SMAppService.mainApp.register()
                return (true, nil)
            } else {
                try SMAppService.mainApp.unregister()
                return (true, nil)
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
