import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

struct LaunchAtLoginUpdateResult {
    let config: AppConfig
    let error: Error?
}

struct LaunchAtLoginCoordinator {
    let manager: LaunchAtLoginManaging

    func reconcileOnStartup(config: AppConfig) -> LaunchAtLoginUpdateResult {
        if config.launchAtLogin, !manager.isEnabled {
            return setEnabled(true, config: config)
        }

        var updated = config
        updated.launchAtLogin = manager.isEnabled
        return LaunchAtLoginUpdateResult(config: updated, error: nil)
    }

    func setEnabled(_ enabled: Bool, config: AppConfig) -> LaunchAtLoginUpdateResult {
        var updated = config
        do {
            try manager.setEnabled(enabled)
            updated.launchAtLogin = manager.isEnabled
            return LaunchAtLoginUpdateResult(config: updated, error: nil)
        } catch {
            updated.launchAtLogin = manager.isEnabled
            return LaunchAtLoginUpdateResult(config: updated, error: error)
        }
    }
}

final class SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        switch (enabled, service.status) {
        case (true, .enabled), (false, .notRegistered):
            return
        case (true, _):
            try service.register()
        case (false, _):
            try service.unregister()
        }
    }
}
