import XCTest

#if LOCAL_BUILD
final class PersonalConfigurationUITests: XCTestCase {
    @MainActor
    func testDashboardAndSettingsPreservePersonalConfiguration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedOnboardingV2", "YES",
            "-IsMenuBarOnly", "NO",
            "-enableAnnouncements", "NO",
            "-AppleLanguages", "(en)",
            "-SUEnableAutomaticChecks", "YES",
            "-VoiceInkChecksForUpdatesOnLaunch", "YES",
            "-VoiceInkLicenseRemovalPending", "YES",
            "-VoiceInkLicenseRequiresActivation", "YES",
            "-VoiceInkActivationsLimit", "0",
        ]
        app.launch()
        defer { app.terminate() }

        let dashboard = app.buttons["Dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 20))
        dashboard.click()
        XCTAssertFalse(app.buttons["VoiceInk Pro"].exists)
        XCTAssertFalse(app.staticTexts["Activate a license to continue using VoiceInk."].exists)

        app.buttons["Settings"].click()
        let updatePreference = app.switches["settings.automaticUpdates"]
        XCTAssertTrue(updatePreference.waitForExistence(timeout: 10))
        XCTAssertFalse(updatePreference.isEnabled)
        XCTAssertEqual((updatePreference.value as? NSNumber)?.intValue, 0)
        XCTAssertFalse(app.buttons["Check for Updates"].isEnabled)
    }
}
#endif
