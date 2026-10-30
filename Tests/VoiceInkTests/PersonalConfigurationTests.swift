import Foundation
import XCTest
@testable import VoiceInk

final class PersonalConfigurationTests: XCTestCase {
    @MainActor
    func testLegacyLicenseStageResumesAtTrust() throws {
        try withIsolatedDefaults { defaults in
            defaults.set("license", forKey: OnboardingStorageKeys.stage)
            defaults.set(true, forKey: "VoiceInkLicenseRemovalPending")
            defaults.set(0, forKey: "VoiceInkActivationsLimit")

            let coordinator = OnboardingCoordinator(defaults: defaults)

            XCTAssertEqual(coordinator.stage, .trust)
            XCTAssertEqual(coordinator.currentStepNumber, coordinator.totalStepCount)
            XCTAssertFalse(OnboardingStage.allCases.map(\.rawValue).contains("license"))
        }
    }

    @MainActor
    func testTrustIsFinalStepWithAndWithoutAPISetup() throws {
        try withIsolatedDefaults { defaults in
            let coordinator = OnboardingCoordinator(defaults: defaults)
            coordinator.storedStage = OnboardingStage.trust.rawValue

            let fullExperienceCount = coordinator.activeExperienceSteps.count
            XCTAssertEqual(coordinator.currentStepNumber, coordinator.totalStepCount)

            coordinator.hasSkippedAPISetup = true
            coordinator.isSelectedAPIProviderVerified = false

            XCTAssertLessThan(coordinator.activeExperienceSteps.count, fullExperienceCount)
            XCTAssertEqual(coordinator.currentStepNumber, coordinator.totalStepCount)
        }
    }

    @MainActor
    func testReadySetupCanReachFinalTrustStepWithoutLicenseData() throws {
        try withIsolatedDefaults { defaults in
            let coordinator = readyCoordinator(defaults: defaults)
            coordinator.storedStage = OnboardingStage.experience.rawValue

            coordinator.flow.goToTrustStep(isTranscriptionSetupReady: true)

            XCTAssertEqual(coordinator.stage, .trust)
            XCTAssertEqual(defaults.string(forKey: OnboardingStorageKeys.stage), "trust")
            XCTAssertEqual(coordinator.currentStepNumber, coordinator.totalStepCount)
        }
    }

    @MainActor
    func testRemovingLicenseStepPreservesRequiredSetupGuards() throws {
        try withIsolatedDefaults { defaults in
            let coordinator = readyCoordinator(defaults: defaults)
            coordinator.storedStage = OnboardingStage.experience.rawValue

            coordinator.flow.goToTrustStep(isTranscriptionSetupReady: false)
            XCTAssertEqual(coordinator.stage, .experience)

            coordinator.permissionStatuses[.accessibility] = .denied
            coordinator.flow.goToTrustStep(isTranscriptionSetupReady: true)
            XCTAssertEqual(coordinator.stage, .experience)

            coordinator.permissionStatuses[.accessibility] = .granted
            defaults.selectedAudioDeviceUID = nil
            coordinator.flow.goToTrustStep(isTranscriptionSetupReady: true)
            XCTAssertEqual(coordinator.stage, .experience)

            defaults.selectedAudioDeviceUID = "personal-build-test-microphone"
            coordinator.hasSkippedAPISetup = false
            coordinator.isSelectedAPIProviderVerified = false
            coordinator.flow.goToTrustStep(isTranscriptionSetupReady: true)
            XCTAssertEqual(coordinator.stage, .experience)
        }
    }

    @MainActor
    func testNavigationRejectsLegacyPurchaseDestination() {
        let navigation = MainWindowNavigation.shared
        let previousSelection = navigation.selectedView
        defer { navigation.selectedView = previousSelection }

        navigation.navigate(to: .settings)
        navigation.navigate(to: "VoiceInk Pro")

        XCTAssertEqual(navigation.selectedView, .settings)
        XCTAssertNil(ViewType(rawValue: "VoiceInk Pro"))
        XCTAssertFalse(ViewType.allCases.contains { destination in
            let title = destination.rawValue.lowercased()
            return title == "voiceink pro" || title.contains("license") || title.contains("purchase")
                || title.contains("trial")
        })
    }

    @MainActor
    func testDiagnosticsAlwaysReportProRegardlessOfLegacyLicensePreferences() {
        withVolatileDefaults([
            "VoiceInkLicenseRemovalPending": true,
            "VoiceInkLicenseRequiresActivation": true,
            "VoiceInkActivationsLimit": 0,
        ]) {
            let info = SystemInfoService.shared.getSystemInfoString()

            XCTAssertTrue(info.contains("Pro Access: Always enabled (personal build)"))
            XCTAssertFalse(info.contains("Not Licensed"))
            XCTAssertFalse(info.contains("Cleanup Pending"))
            XCTAssertFalse(info.contains("License Status:"))
        }
    }

    @MainActor
    func testPastePreservesTranscriptAndResolvesAutoSendBeforeDelivery() async {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }

        let text = "Personal transcript.\nQuotes: ' \" & $() and Unicode: café."
        for appendSpace in [false, true] {
            for sendAfterPaste in [false, true] {
                for modeKey in FinishAndSendKey.allCases {
                    let values: [String: Any] = [
                        "AppendTrailingSpace": appendSpace,
                        FinishAndSendSettings.key: FinishAndSendKey.commandEnter.rawValue,
                        "VoiceInkLicenseRemovalPending": true,
                        "VoiceInkLicenseRequiresActivation": true,
                        "VoiceInkActivationsLimit": 0,
                    ]
                    defaults.setVolatileDomain(
                        original.merging(values) { _, testValue in testValue },
                        forName: UserDefaults.argumentDomain
                    )

                    var events: [String] = []
                    let delivery = TranscriptionDelivery { pastedText, sendKey in
                        XCTAssertEqual(events, ["idle", "dismiss"])
                        XCTAssertEqual(pastedText, text + (appendSpace ? " " : ""))
                        XCTAssertEqual(sendKey, sendAfterPaste ? .commandEnter : modeKey)
                        events.append("paste")
                        return Task { CursorPaster.PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil) }
                    }
                    let request = TranscriptionDelivery.Request(
                        transcription: Transcription(text: text, duration: 1, transcriptionStatus: .completed),
                        text: text,
                        output: OutputRuntimeConfiguration(
                            mode: nil, outputMode: .paste, autoSendKey: modeKey, customCommand: nil
                        ),
                        responseConfig: nil,
                        responseError: nil,
                        isAssistantFollowUp: false,
                        sendAfterPaste: sendAfterPaste
                    )
                    let actions = TranscriptionDelivery.Actions(
                        setState: { state in
                            guard case .idle = state else {
                                XCTFail("Paste delivery must leave the recorder idle")
                                return
                            }
                            events.append("idle")
                        },
                        dismiss: { events.append("dismiss") },
                        sendFollowUp: { _, _ in XCTFail("Paste must not send an assistant follow-up") },
                        showResponse: { _, _ in XCTFail("Paste must not show an assistant response") },
                        failResponse: { _ in XCTFail("Paste must not show a response error") }
                    )

                    await delivery.deliver(request, actions: actions)

                    XCTAssertEqual(events, ["idle", "dismiss", "paste"])
                }
            }
        }
    }

    @MainActor
    func testCustomCommandReceivesOnlyTranscriptThroughStandardInputAndEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceInkPersonalConfigurationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("standard-input.txt")
        let environmentURL = directory.appendingPathComponent("environment.txt")
        let completionURL = directory.appendingPathComponent("completed")
        let command = """
            /bin/cat > \(shellQuoted(inputURL.path)) && \
            /usr/bin/printf '%s' "$VOICEINK_TRANSCRIPT" > \(shellQuoted(environmentURL.path)) && \
            /usr/bin/touch \(shellQuoted(completionURL.path))
            """
        let text = "Personal build transcript.\nQuotes: ' \" & $() and Unicode: café."
        let transcription = Transcription(text: text, duration: 1, transcriptionStatus: .completed)
        let request = TranscriptionDelivery.Request(
            transcription: transcription,
            text: text,
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .customCommand,
                autoSendKey: .none,
                customCommand: ModeCustomCommand(command: command)
            ),
            responseConfig: nil,
            responseError: nil,
            isAssistantFollowUp: false,
            sendAfterPaste: false
        )
        var dismissCount = 0
        let actions = TranscriptionDelivery.Actions(
            setState: { _ in XCTFail("Custom command delivery should not change recording state") },
            dismiss: { dismissCount += 1 },
            sendFollowUp: { _, _ in XCTFail("Custom command delivery should not send an assistant follow-up") },
            showResponse: { _, _ in XCTFail("Custom command delivery should not show an assistant response") },
            failResponse: { _ in XCTFail("Custom command delivery should not show a response error") }
        )

        await TranscriptionDelivery().deliver(request, actions: actions)

        let deadline = Date().addingTimeInterval(12)
        while !FileManager.default.fileExists(atPath: completionURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(dismissCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completionURL.path), "Custom command did not finish")
        XCTAssertEqual(try String(contentsOf: inputURL, encoding: .utf8), text)
        XCTAssertEqual(try String(contentsOf: environmentURL, encoding: .utf8), text)
    }

    #if LOCAL_BUILD
    @MainActor
    func testPersonalBuildIgnoresPersistedAutomaticUpdatePreferences() {
        withVolatileDefaults([
            "SUEnableAutomaticChecks": true,
            "VoiceInkChecksForUpdatesOnLaunch": true,
        ]) {
            let updater = UpdaterViewModel()

            XCTAssertFalse(updater.canCheckForUpdates)
            XCTAssertFalse(updater.checksForUpdatesWhenDashboardAppears)
            XCTAssertNil(updater.availableUpdate)

            updater.checkForUpdatesIfDue()
            updater.checkForUpdates()

            XCTAssertFalse(updater.canCheckForUpdates)
            XCTAssertFalse(updater.checksForUpdatesWhenDashboardAppears)
            XCTAssertNil(updater.availableUpdate)
        }
    }

    @MainActor
    func testPersonalBuildCannotEnableAutomaticUpdates() {
        withVolatileDefaults([
            "SUEnableAutomaticChecks": true,
            "VoiceInkChecksForUpdatesOnLaunch": false,
        ]) {
            let updater = UpdaterViewModel()

            updater.setChecksForUpdatesWhenDashboardAppears(true)

            XCTAssertFalse(updater.checksForUpdatesWhenDashboardAppears)
            XCTAssertFalse(updater.canCheckForUpdates)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "VoiceInkChecksForUpdatesOnLaunch"))
        }
    }
    #endif

    @MainActor
    private func readyCoordinator(defaults: UserDefaults) -> OnboardingCoordinator {
        defaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
        defaults.selectedAudioDeviceUID = "personal-build-test-microphone"
        let coordinator = OnboardingCoordinator(defaults: defaults)
        coordinator.permissionStatuses = [.microphone: .granted, .accessibility: .granted]
        coordinator.hasSkippedAPISetup = true
        return coordinator
    }

    @MainActor
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "VoiceInkPersonalConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @MainActor
    private func withVolatileDefaults(_ values: [String: Any], body: () -> Void) {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let overridden = original.merging(values) { _, testValue in testValue }
        defaults.setVolatileDomain(overridden, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        body()
    }

    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
