import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Launch at login")
struct LaunchAtLoginManagerTests {
    @Test("startup reconciliation reflects actual enabled status when config is off")
    func startupReconciliationReflectsActualEnabledStatus() {
        var config = AppConfig()
        config.launchAtLogin = false
        let manager = FakeLaunchAtLoginManager(isEnabled: true)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.reconcileOnStartup(config: config)

        #expect(result.error == nil)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests.isEmpty)
    }

    @Test("startup reconciliation applies legacy saved enabled setting")
    func startupReconciliationAppliesLegacySavedEnabledSetting() {
        var config = AppConfig()
        config.launchAtLogin = true
        let manager = FakeLaunchAtLoginManager(isEnabled: false)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.reconcileOnStartup(config: config)

        #expect(result.error == nil)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests == [true])
    }

    @Test("setting launch at login delegates to backend and stores actual status")
    func settingLaunchAtLoginUsesBackendStatus() {
        var config = AppConfig()
        config.launchAtLogin = false
        let manager = FakeLaunchAtLoginManager(isEnabled: false)
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.setEnabled(true, config: config)

        #expect(result.error == nil)
        #expect(result.config.launchAtLogin)
        #expect(manager.requests == [true])
    }

    @Test("failed backend update rolls config back to actual status")
    func failedBackendUpdateRollsBackConfig() {
        var config = AppConfig()
        config.launchAtLogin = true
        let manager = FakeLaunchAtLoginManager(isEnabled: false)
        manager.errorToThrow = TestLaunchAtLoginError.denied
        let coordinator = LaunchAtLoginCoordinator(manager: manager)

        let result = coordinator.setEnabled(true, config: config)

        #expect(result.error != nil)
        #expect(result.config.launchAtLogin == false)
        #expect(manager.requests == [true])
    }
}

private enum TestLaunchAtLoginError: Error {
    case denied
}

private final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool
    var requests: [Bool] = []
    var errorToThrow: Error?

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        if let errorToThrow {
            throw errorToThrow
        }
        isEnabled = enabled
    }
}
