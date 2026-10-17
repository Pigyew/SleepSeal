import Foundation

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}
private let uid: UInt32 = 501
private let ownPID: Int32 = 42
private let launch = Date(timeIntervalSince1970: 1000)
private func app(_ pid: Int32 = 100, uid: UInt32 = 501, bundle: String = "org.example.Editor",
                 launchDate: Date = launch, name: String = "Editor", regular: Bool = true,
                 executablePath: String = "/Applications/Editor.app/Contents/MacOS/Editor") -> BlockingAppIdentity {
    BlockingAppIdentity(pid: pid, uid: uid, bundleID: bundle, launchDate: launchDate,
                        displayName: name, activationRegular: regular, executablePath: executablePath)
}
private func enabledConfiguration(policy: TriggerPolicy = TriggerPolicy()) -> AppConfiguration {
    AppConfiguration(existingInstallation: true, triggerPolicy: policy, quitBlockingApps: true)
}
private func begin(_ coordinator: BlockingAppsCoordinator, configuration: AppConfiguration = enabledConfiguration(),
                   owner: Bool = true, idle: TimeInterval = 600, system: Int? = 10, display: Int? = 5,
                   assertions: [BlockingSleepAssertion] = [BlockingSleepAssertion(pid: 100, kind: .system)],
                   applications: [BlockingAppIdentity] = [app()], at time: TimeInterval = 1000,
                   budget: TimeInterval = 2, origin: SleepOrigin = .idle,
                   requiresIdleThreshold: Bool = true, selected: Bool? = nil) -> BlockingAppsBatch? {
    coordinator.begin(configuration: configuration, isConsoleOwner: owner, inputIdleSeconds: idle,
                      systemSleepMinutes: system, displaySleepMinutes: display, assertions: assertions,
                      applications: applications, currentUID: uid, ownPID: ownPID, at: time,
                      budget: budget, origin: origin, requiresIdleThreshold: requiresIdleThreshold,
                      protectionSelected: selected)
}

@main struct BlockingAppsPolicyTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("new and migrated configurations keep app closing off", defaultOff),
            ("old settings decode with app closing disabled", backwardConfiguration),
            ("only opt-in selected protection can request quits", configurationGate),
            ("other accounts and privileged processes are excluded", userBoundary),
            ("essential services and SleepSeal are excluded", essentialApps),
            ("missing process identity and agents are excluded", incompleteIdentity),
            ("ordinary browsers and user apps remain eligible", ordinaryApplications),
            ("assertions are deduplicated by a complete process identity", deduplication),
            ("only active matching blocker pids can be selected", activeAssertion),
            ("ambiguous pid metadata is rejected", ambiguousPID),
            ("idle actions wait for their actual per-kind timers", idleThresholds),
            ("Never and unknown timers do not start idle app closing", neverTimers),
            ("explicit selected sleep can request normal quit without idle delay", explicitSelectedSleep),
            ("actual sleep honors its frozen trigger decision", frozenDecision),
            ("pid reuse and changed executable identity are rejected", pidReuse),
            ("claim revalidates current uid and activation policy", claimRevalidatesEligibility),
            ("expired and canceled batches cannot request quits", deadlines),
            ("canceling a save prompt does not produce repeated requests", canceledSavePrompt),
            ("new user activity starts a new idle episode", inputReset),
            ("wake disable and explicit sleep invalidate queued work", explicitResets),
            ("invalid measurements and budgets are rejected", invalidInputs),
            ("a batch limits work while preserving remaining candidates", boundedBatch)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) blocking-app policy tests passed; no apps were closed or signaled.")
    }
    static func defaultOff() throws {
        let fresh = AppConfiguration()
        let migrated = AppConfiguration(existingInstallation: true)
        try expect(!fresh.quitBlockingApps && !migrated.quitBlockingApps, "App closing became enabled without consent")
        try expect(begin(BlockingAppsCoordinator(), configuration: migrated) == nil, "Migrated setting closed apps")
    }
    static func backwardConfiguration() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(enabledConfiguration())) as! [String: Any]
        object.removeValue(forKey: "quitBlockingApps")
        let old = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(old.onboardingCompleted && !old.quitBlockingApps, "Old configuration enabled closing")
        let enabled = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(enabledConfiguration()))
        try expect(enabled.quitBlockingApps, "Explicit consent did not round-trip")
    }
    static func configurationGate() throws {
        var configuration = enabledConfiguration()
        configuration.protectionPaused = true
        try expect(begin(BlockingAppsCoordinator(), configuration: configuration) == nil, "Paused protection closed apps")
        configuration.protectionPaused = false; configuration.onboardingCompleted = false
        try expect(begin(BlockingAppsCoordinator(), configuration: configuration) == nil, "Unconfirmed onboarding closed apps")
        let manualOnly = enabledConfiguration(policy: TriggerPolicy(mode: .custom, sources: [.manual]))
        try expect(begin(BlockingAppsCoordinator(), configuration: manualOnly) == nil, "Unselected idle source closed apps")
        try expect(begin(BlockingAppsCoordinator(), owner: false) == nil, "Background account closed apps")
    }
    static func userBoundary() throws {
        let applications = [app(100, uid: 0), app(101, uid: 502), app(102, uid: uid)]
        let assertions = applications.map { BlockingSleepAssertion(pid: $0.pid, kind: .system) }
        let result = BlockingAppsPolicy.select(assertions: assertions, applications: applications, currentUID: uid, ownPID: ownPID)
        try expect(result.map(\.pid) == [102], "Wrong user or root process was selected")
        try expect(BlockingAppsPolicy.select(assertions: assertions, applications: applications, currentUID: 0, ownPID: ownPID).isEmpty,
                   "Privileged caller could close apps")
    }
    static func essentialApps() throws {
        for bundle in BlockingAppsPolicy.excludedBundleIDs {
            let candidate = app(bundle: bundle.uppercased())
            try expect(!BlockingAppsPolicy.eligible(candidate, currentUID: uid, ownPID: ownPID), "Essential app \(bundle) accepted")
        }
        try expect(!BlockingAppsPolicy.eligible(app(ownPID), currentUID: uid, ownPID: ownPID), "Own process selected under a different bundle id")
    }
    static func incompleteIdentity() throws {
        let invalid = [app(1), app(-1), app(bundle: ""), app(bundle: "  "), app(regular: false),
                       app(launchDate: Date(timeIntervalSince1970: 0)), app(executablePath: ""),
                       app(executablePath: "relative/path"), app(executablePath: "/path\0suffix")]
        for candidate in invalid {
            try expect(!BlockingAppsPolicy.eligible(candidate, currentUID: uid, ownPID: ownPID), "Incomplete identity was accepted")
        }
    }
    static func ordinaryApplications() throws {
        for bundle in ["com.apple.Safari", "com.google.Chrome", "com.openai.chat", "org.example.Editor"] {
            try expect(BlockingAppsPolicy.eligible(app(bundle: bundle), currentUID: uid, ownPID: ownPID), "Ordinary user app excluded")
        }
    }
    static func deduplication() throws {
        let candidate = app()
        let assertions = [BlockingSleepAssertion(pid: 100, kind: .system), BlockingSleepAssertion(pid: 100, kind: .display), BlockingSleepAssertion(pid: 100, kind: .system)]
        let result = BlockingAppsPolicy.select(assertions: assertions, applications: [candidate, candidate], currentUID: uid, ownPID: ownPID)
        try expect(result == [candidate], "One app received duplicate requests for multiple assertions")
    }
    static func activeAssertion() throws {
        try expect(BlockingAppsPolicy.select(assertions: [], applications: [app()], currentUID: uid, ownPID: ownPID).isEmpty, "Non-blocker selected")
        try expect(BlockingAppsPolicy.select(assertions: [BlockingSleepAssertion(pid: 999, kind: .system)], applications: [app()], currentUID: uid, ownPID: ownPID).isEmpty,
                   "Unmatched assertion selected an unrelated app")
    }
    static func ambiguousPID() throws {
        let reused = app(launchDate: launch.addingTimeInterval(1))
        let result = BlockingAppsPolicy.select(assertions: [BlockingSleepAssertion(pid: 100, kind: .system)], applications: [app(), reused], currentUID: uid, ownPID: ownPID)
        try expect(result.isEmpty, "Conflicting identity for one pid was accepted")
    }
    static func idleThresholds() throws {
        let systemAssertion = [BlockingSleepAssertion(pid: 100, kind: .system)]
        let displayAssertion = [BlockingSleepAssertion(pid: 100, kind: .display)]
        try expect(begin(BlockingAppsCoordinator(), idle: 599.9, system: 10, assertions: systemAssertion) == nil, "System blocker closed before system timer")
        try expect(begin(BlockingAppsCoordinator(), idle: 600, system: 10, assertions: systemAssertion) != nil, "System timer match was skipped")
        try expect(begin(BlockingAppsCoordinator(), idle: 299.9, display: 5, assertions: displayAssertion) == nil, "Display blocker closed before display timer")
        try expect(begin(BlockingAppsCoordinator(), idle: 300, display: 5, assertions: displayAssertion) != nil, "Display timer match was skipped")
        try expect(begin(BlockingAppsCoordinator(), idle: 300, system: 20, display: 5, assertions: systemAssertion) == nil, "Display timer was applied to a system assertion")
    }
    static func neverTimers() throws {
        for timer: Int? in [nil, 0, -1] {
            try expect(begin(BlockingAppsCoordinator(), idle: 999999, system: timer) == nil, "Never or unknown timer closed a system blocker")
            try expect(begin(BlockingAppsCoordinator(), idle: 999999, display: timer,
                             assertions: [BlockingSleepAssertion(pid: 100, kind: .display)]) == nil, "Never or unknown timer closed a display blocker")
        }
    }
    static func explicitSelectedSleep() throws {
        for origin: SleepOrigin in [.manual, .lid, .hotCorner(.topLeft)] {
            let configuration = enabledConfiguration(policy: TriggerPolicy(mode: .custom, sources: [origin.trigger!]))
            let result = begin(BlockingAppsCoordinator(), configuration: configuration, idle: 0, system: 0, display: 0,
                               origin: origin, requiresIdleThreshold: false)
            try expect(result?.applications == [app()], "Selected explicit source incorrectly waited for idle timer")
        }
    }
    static func frozenDecision() throws {
        let none = enabledConfiguration(policy: TriggerPolicy(mode: .custom, sources: []))
        try expect(begin(BlockingAppsCoordinator(), configuration: none, idle: 0, origin: .unknown,
                         requiresIdleThreshold: false, selected: true) != nil, "Frozen protected cycle lost its selection")
        try expect(begin(BlockingAppsCoordinator(), idle: 0, origin: .manual,
                         requiresIdleThreshold: false, selected: false) == nil, "Unselected frozen decision was ignored")
    }
    static func pidReuse() throws {
        let coordinator = BlockingAppsCoordinator()
        let batch = begin(coordinator)!
        let mutations = [app(101), app(uid: 502), app(bundle: "org.example.Other"),
                         app(launchDate: launch.addingTimeInterval(0.000001)), app(executablePath: "/Applications/Other.app/Contents/MacOS/Other")]
        for changed in mutations {
            try expect(!coordinator.claim(app(), in: batch, current: changed, at: 1000.1), "PID reuse or changed executable was accepted")
        }
        try expect(coordinator.claim(app(), in: batch, current: app(), at: 1000.2), "Failed identity check consumed a valid request")
    }
    static func claimRevalidatesEligibility() throws {
        let coordinator = BlockingAppsCoordinator()
        let batch = begin(coordinator)!
        try expect(!coordinator.claim(app(), in: batch, current: app(regular: false), at: 1000.1), "App becoming an agent was accepted")
        try expect(coordinator.claim(app(), in: batch, current: app(name: "Changed title"), at: 1000.2), "Display-name change incorrectly became process identity")
    }
    static func deadlines() throws {
        let coordinator = BlockingAppsCoordinator()
        let batch = begin(coordinator)!
        try expect(!coordinator.claim(app(), in: batch, current: app(), at: 999), "Request before batch creation was accepted")
        try expect(!coordinator.claim(app(), in: batch, current: app(), at: batch.deadline), "Expired request was accepted")
        let canceled = begin(coordinator, at: 1010)!
        coordinator.cancelActiveBatch()
        try expect(!coordinator.claim(app(), in: canceled, current: app(), at: 1010.1), "Canceled batch still requested quit")
    }
    static func canceledSavePrompt() throws {
        let coordinator = BlockingAppsCoordinator()
        let batch = begin(coordinator)!
        try expect(coordinator.claim(app(), in: batch, current: app(), at: 1000.1), "First request refused")
        // Native normal termination may return false, or the user may cancel a
        // save prompt. Neither result authorizes a second request this episode.
        try expect(!coordinator.claim(app(), in: batch, current: app(), at: 1000.2), "Same batch repeated a quit prompt")
        try expect(begin(coordinator, idle: 610, at: 1010) == nil, "Ten-second polling repeated a canceled quit prompt")
        try expect(begin(coordinator, idle: 900, at: 1300) == nil, "Long idle wait repeated a canceled quit prompt")
    }
    static func inputReset() throws {
        let coordinator = BlockingAppsCoordinator()
        let batch = begin(coordinator)!
        _ = coordinator.claim(app(), in: batch, current: app(), at: 1000.1)
        try expect(begin(coordinator, idle: 1, at: 1010) == nil, "User input immediately bypassed the idle timer")
        let next = begin(coordinator, idle: 600, at: 1609)
        try expect(next != nil, "New idle episode did not reset cooldown")
        try expect(!coordinator.claim(app(), in: batch, current: app(), at: 1000.2), "User input did not invalidate old queued work")
    }
    static func explicitResets() throws {
        for reason: BlockingAppsResetReason in [.wake, .explicitSleep, .configurationDisabled, .protectionPaused, .userActivity] {
            let coordinator = BlockingAppsCoordinator()
            let batch = begin(coordinator)!
            _ = coordinator.claim(app(), in: batch, current: app(), at: 1000.1)
            coordinator.reset(reason: reason)
            try expect(!coordinator.claim(app(), in: batch, current: app(), at: 1000.2), "Reset left queued work authorized")
            try expect(begin(coordinator, idle: 610, at: 1010) != nil, "Reset did not clear the previous idle episode")
        }
    }
    static func invalidInputs() throws {
        for idle in [Double.nan, Double.infinity, -1] { try expect(begin(BlockingAppsCoordinator(), idle: idle) == nil, "Invalid idle value accepted") }
        for time in [Double.nan, Double.infinity, -1] { try expect(begin(BlockingAppsCoordinator(), at: time) == nil, "Invalid uptime accepted") }
        for budget in [Double.nan, Double.infinity, -1, 0, 10.1] { try expect(begin(BlockingAppsCoordinator(), budget: budget) == nil, "Unbounded operation budget accepted") }
    }
    static func boundedBatch() throws {
        let candidates = (100..<150).map { app(Int32($0)) }
        let assertions = candidates.map { BlockingSleepAssertion(pid: $0.pid, kind: .system) }
        let coordinator = BlockingAppsCoordinator()
        let batch = begin(coordinator, assertions: assertions, applications: candidates)!
        try expect(batch.applications.count == 32, "One UI event queued unbounded quit requests")
        for candidate in batch.applications { _ = coordinator.claim(candidate, in: batch, current: candidate, at: 1000.1) }
        let remaining = begin(coordinator, idle: 610, assertions: assertions, applications: candidates, at: 1010)!
        try expect(remaining.applications.count == 18, "Unattempted candidates were lost or previously prompted apps repeated")
    }
}
