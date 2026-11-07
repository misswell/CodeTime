import Foundation
import ServiceManagement

enum LaunchAgentManager {
    static let plistName = "com.codetime.agent.plist"

    enum State {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown
    }

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

    static var state: State {
        switch SMAppService.agent(plistName: plistName).status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
}
