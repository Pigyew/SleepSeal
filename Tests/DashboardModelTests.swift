import Foundation

/// Model-only checks: no NSApplication, window, controller, hardware or XPC.
@main
@MainActor
private struct DashboardModelTests {
    private static var checks = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() throws {
        onboarding()
        readinessAndVersion()
        powerValidation()
        quitConfirmation()
        try localization()
        print("PASS: dashboard model onboarding, readiness, power validation, confirmation and localization — \(checks) checks; no windows or hardware used")
    }

    private static func onboarding() {
        let model = DashboardModel()
        model.updateOnboarding(completed: false)
        check(model.onboardingRequired && !model.isEnabled, "First setup offers onboarding without enabling protection")
        model.deferOnboarding()
        for _ in 0..<3 { model.updateOnboarding(completed: false) }
        check(!model.onboardingRequired && !model.isEnabled, "Refresh must preserve Set up later in the same process")
        model.showOnboarding()
        check(model.onboardingRequired, "An explicit setup action can reopen a deferred sheet")
        model.updateOnboarding(completed: false)
        check(model.onboardingRequired, "Refresh must preserve explicitly reopened setup")
        model.updateOnboarding(completed: true)
        check(!model.onboardingRequired, "Confirmed completion closes onboarding")
        model.showOnboarding()
        check(!model.onboardingRequired, "Completed setup is not presented as uncompleted onboarding")

        let recovery = DashboardModel()
        recovery.updateOnboarding(completed: false, canConfigure: false)
        check(!recovery.onboardingRequired, "Unavailable settings leave recovery controls reachable instead of opening setup")
        recovery.showOnboarding()
        check(!recovery.onboardingRequired, "Explicit setup cannot bypass unavailable configuration")
        recovery.updateOnboarding(completed: false, canConfigure: true)
        check(recovery.onboardingRequired, "Restored configuration can still offer genuinely unfinished setup")
        recovery.deferOnboarding()
        recovery.updateOnboarding(completed: false, canConfigure: false)
        recovery.updateOnboarding(completed: false, canConfigure: true)
        check(!recovery.onboardingRequired, "Repairing settings does not forget a user-deferred offer")
        recovery.isBusy = true
        recovery.showOnboarding()
        check(!recovery.onboardingRequired, "A busy operation does not open another setup sheet")
        recovery.isBusy = false
        recovery.showOnboarding()
        check(recovery.onboardingRequired, "Setup remains available after the busy operation finishes")
        let restarted = DashboardModel()
        restarted.updateOnboarding(completed: false)
        check(restarted.onboardingRequired, "Set up later does not falsely persist setup completion across processes")
    }

    private static func readinessAndVersion() {
        let model = DashboardModel.mock()
        check(model.canUseActions && model.settingsReady && model.powerPreferencesReady, "Ready mocks preserve ordinary action availability")
        model.settingsReady = false
        check(!model.canUseActions, "Unreadable settings disable protected sleep actions")
        var restored = false
        model.onAction = { if case .restoreProtection = $0 { restored = true } }
        model.send(.restoreProtection)
        check(restored, "Recovery remains dispatchable when configuration is unavailable")
        model.settingsReady = true
        model.isBusy = true
        check(!model.canUseActions, "Busy state disables duplicate protected actions")
        model.isBusy = false
        model.serviceAvailable = false
        check(!model.canUseActions, "Unavailable service disables protected actions")
        model.serviceAvailable = true
        model.isEnabled = false
        check(!model.canUseActions, "Unenabled protection cannot use protected actions")
        check(DashboardModel.versionLabel(infoDictionary: ["CFBundleShortVersionString": "9.7.3"]) == "9.7.3", "Version follows bundle metadata")
        check(DashboardModel.versionLabel(infoDictionary: nil) == "Development", "Unbundled development has an honest fallback")
        check(DashboardModel.versionLabel(infoDictionary: ["CFBundleShortVersionString": " \n"]) == "Development", "Empty bundle versions use the development fallback")
        check(model.appVersion == DashboardModel.versionLabel(infoDictionary: Bundle.main.infoDictionary), "Displayed default version is derived from the running bundle")
    }

    private static func powerValidation() {
        let model = DashboardModel.mock(page: .power)
        var writes: [[UIPowerEdit]] = []
        model.onAction = { if case .applyPower(let edits) = $0 { writes.append(edits) } }
        check(!model.powerDirty && model.powerEdits()?.isEmpty == true, "Reading existing profiles creates no writes")
        for invalid in ["-1", "1441", "1.5", "NaN", "", " 5 ", "05", "999999999999999999999999"] {
            model.setDraft(invalid, scope: .battery, key: "displaysleep")
            model.applyPower()
            check(model.powerEdits() == nil && writes.isEmpty && model.powerErrorKey == "power.validation", "Invalid timer \(invalid) stays editable and dispatches no write")
        }
        for value in [0, 1, 1440] {
            model.setDraft(String(value), scope: .battery, key: "displaysleep")
            check(model.powerEdits() == [UIPowerEdit(scope: .battery, key: "displaysleep", original: 5, value: value)], "Valid timer boundary \(value) edits only one field")
        }
        model.setDraft("5", scope: .battery, key: "displaysleep")
        check(!model.powerDirty && model.powerErrorKey == nil, "Reverting a draft removes the edit and validation error")
        model.setDraft("60", scope: .adapter, key: "sleep")
        model.page = .settings
        model.page = .power
        check(model.draft(.adapter, "sleep") == "60" && model.draft(.battery, "sleep") == "10", "Navigation preserves drafts independently for each power source")
        model.powerProfiles[.battery]?.values["displaysleep"] = 2880
        check(model.draft(.battery, "displaysleep") == "2880" && model.powerEdits()?.count == 1, "Unusual unedited system values are preserved")
        model.isBusy = true
        model.applyPower()
        model.isBusy = false
        model.powerConflict = true
        model.applyPower()
        model.powerConflict = false
        model.settingsReady = false
        model.applyPower()
        model.settingsReady = true
        model.powerPreferencesReady = false
        model.applyPower()
        model.powerPreferencesReady = true
        model.serviceAvailable = false
        model.applyPower()
        check(writes.isEmpty, "Busy, conflict, unavailable settings, power store or service all block power writes")
        model.serviceAvailable = true
        model.guardPending = true
        model.applyPower()
        check(writes.count == 1 && writes[0] == [UIPowerEdit(scope: .adapter, key: "sleep", original: 30, value: 60)], "Pending recovery still permits independent persistent timer edits")
        model.powerDrafts = [:]
        model.setDraft("2", scope: .battery, key: "powermode")
        check(model.powerEdits() == nil, "Unsupported power modes cannot be applied")
        model.setDraft("1", scope: .battery, key: "powermode")
        model.applyPower()
        check(writes.count == 1 && model.powerErrorKey == "power.modeLocked", "Pending recovery blocks energy-mode writes")
        model.guardPending = false
        model.applyPower()
        check(writes.count == 2 && writes[1] == [UIPowerEdit(scope: .battery, key: "powermode", original: 0, value: 1)], "A supported mode dispatches only after recovery is complete")
    }

    private static func quitConfirmation() {
        let model = DashboardModel.mock(page: .diagnostics)
        var changes: [Bool] = []
        model.onAction = { if case .setQuitBlockingApps(let enabled) = $0 { changes.append(enabled) } }
        model.requestQuitBlockingApps(true)
        check(model.quitBlockingAppsConfirmation && changes.isEmpty && !model.quitBlockingApps, "Opt-in requests a sheet before any setting change")
        model.cancelQuitBlockingApps()
        model.confirmQuitBlockingApps()
        check(changes.isEmpty && !model.quitBlockingAppsConfirmation, "Cancel or confirmation without a sheet never enables quit requests")
        model.requestQuitBlockingApps(true)
        model.isBusy = true
        model.confirmQuitBlockingApps()
        check(changes.isEmpty, "Busy state cannot confirm an already presented opt-in")
        model.isBusy = false
        model.settingsReady = false
        model.confirmQuitBlockingApps()
        check(changes.isEmpty, "Settings becoming unavailable cannot be bypassed by an old confirmation")
        model.settingsReady = true
        model.confirmQuitBlockingApps()
        model.confirmQuitBlockingApps()
        check(changes == [true] && !model.quitBlockingApps, "One confirmation dispatches once and waits for persisted controller state")
        model.quitBlockingApps = true
        model.isBusy = true
        model.requestQuitBlockingApps(false)
        check(changes == [true], "An unrelated busy operation cannot be bypassed by disabling quit requests")
        model.canCancelSleepPreparation = true
        model.requestQuitBlockingApps(false)
        check(changes == [true, false], "An active manual sleep preparation can still be cancelled immediately")
        model.canCancelSleepPreparation = false
        model.quitBlockingApps = false
        model.requestQuitBlockingApps(true)
        check(!model.quitBlockingAppsConfirmation && changes == [true, false], "Busy state prevents another opt-in")
        model.isBusy = false
        model.serviceAvailable = false
        model.requestQuitBlockingApps(true)
        check(!model.quitBlockingAppsConfirmation && changes == [true, false], "Unavailable service cannot start a configuration operation")
    }

    private static func localization() throws {
        check(UILanguage.english.localeIdentifier == "en" && UILanguage.chinese.localeIdentifier == "zh-Hans", "Explicit language preferences resolve independently of the OS")
        check(["en", "zh-Hans"].contains(UILanguage.system.localeIdentifier), "Follow system resolves to a supported language")
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        var previous: Set<String>?
        for code in ["en", "zh-Hans"] {
            let url = root.appendingPathComponent("Resources/\(code).lproj/Localizable.strings")
            let data = try Data(contentsOf: url)
            let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: String]
            let keys = Set(dictionary.keys)
            if let previous { check(previous == keys, "Both languages expose exactly the same message keys") }
            previous = keys
            check(dictionary.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "Localized values cannot be empty")
            let model = DashboardModel.mock(language: code == "en" ? .english : .chinese)
            let modelKeys = [model.statusKey, model.detailKey, model.lastTriggerKey, model.lastRecoveryKey,
                             "power.validation", "power.modeLocked", "onboarding.later", "action.enable"]
                + DashboardPage.allCases.map { "page.\($0.rawValue)" }
                + UITrigger.allCases.map { "trigger.\($0.rawValue)" }
                + [UIActualState.on, .off, .unknown, .unavailable].map(\.key)
            check(modelKeys.allSatisfy { dictionary[$0] != nil }, "Every model state and validation key has a \(code) translation")
        }
    }
}
