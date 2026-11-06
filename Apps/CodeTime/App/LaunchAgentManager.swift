import Foundation
import ServiceManagement

enum LaunchAgentManager {
    static let plistName = "com.codetime.agent.plist"

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.agent(plistName: plistName)
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    static var status: SMAppService.Status {
        SMAppService.agent(plistName: plistName).status
    }
}
