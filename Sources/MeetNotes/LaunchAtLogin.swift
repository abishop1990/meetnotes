import Foundation
import ServiceManagement

/// Registers the app bundle as a login item through SMAppService, so it shows up under
/// System Settings → General → Login Items and can be removed there too.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval in System Settings → Login Items"
        case .notFound: return "not found (run from the .app bundle)"
        @unknown default: return "unknown"
        }
    }
}
