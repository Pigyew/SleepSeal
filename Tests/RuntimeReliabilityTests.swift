import Foundation

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(description: message) }
}

private final class MockRecoverySystem: GuardSystem {
    let original = Snapshot(wifi: ["mock-wifi": true], bluetooth: true,
                            power: [PowerValue(scope: "-b", key: "powermode", value: 0)])
    var restores: [Snapshot] = []
    func capture() throws -> Snapshot { original }
    func suppress(_ snapshot: Snapshot) throws { }
    func restore(_ snapshot: Snapshot) throws { restores.append(snapshot) }
}

private final class FixtureRecoveryStore: GuardStore {
    let url: URL
    init(directory: URL) { url = directory.appendingPathComponent("pending.json") }
    func load() throws -> PendingState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PendingState.self, from: Data(contentsOf: url))
    }
    func save(_ state: PendingState) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
    func clear() throws { try FileManager.default.removeItem(at: url) }
}

private struct NoHardwarePowerAdapter: PowerPreferencesAdapter {
    func read() throws -> PowerPreferencesSnapshot { PowerPreferencesSnapshot(values: []) }
    func write(_ value: PowerPreferenceValue, restoring: Bool) throws {
        throw CheckFailure(description: "These runtime tests must never request a power write")
    }
}

private final class QueuedUnlockResult {
    var error: Error?
    var rejected = false
    var gateAtExecution: UUID?
}

@main struct RuntimeReliabilityTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("broken app settings preserve files and permit pending recovery", { try damagedSettings("configuration") }),
            ("future app schema preserves files and permits pending recovery", { try damagedSettings("future-schema") }),
            ("broken power backup preserves files and permits pending recovery", { try damagedSettings("power") }),
            ("both damaged settings stores retain independent errors and recovery", { try damagedSettings("both") }),
            ("healthy settings remain available without rewriting either store", healthySettings),
            ("broken configuration can launch repair without changing login settings", { try startupLoginFallback(futureSchema: false) }),
            ("future configuration can launch repair without rewriting its schema", { try startupLoginFallback(futureSchema: true) }),
            ("healthy startup honors either saved login preference", healthyStartupLogin),
            ("diagnostic refresh cannot erase unresolved startup or operation failures", failureLifetimes),
            ("refresh cadence covers pending and dashboard visibility", refreshCadence),
            ("outside pointer motion is coalesced while corner transitions survive", pointerTransitions),
            ("startup pointer parked in a corner is never a new entry", parkedStartup),
            ("filtered corner entry uses newly configured sleep action before classification", updatedCornerConfiguration),
            ("queued old unlock cannot authorize a newer sleep gate", { try queuedUnlockInvalidation(newCycle: true) }),
            ("queued old unlock cannot survive a re-lock of the same gate", { try queuedUnlockInvalidation(newCycle: false) })
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) runtime reliability scenarios passed using temporary JSON and mocked hardware; no system settings changed.")
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SleepSeal-runtime-reliability-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func damagedSettings(_ damage: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("configuration.json")
        let configurationStore = AppConfigurationStore(fileURL: configurationURL)
        var configuration = AppConfiguration(existingInstallation: true)
        if damage == "future-schema" { configuration.schemaVersion += 1 }
        try JSONEncoder().encode(configuration).write(to: configurationURL, options: .atomic)
        let powerStore = try JSONPowerPreferencesStore(directory: directory)
        try powerStore.save([])
        if damage == "configuration" || damage == "both" {
            try Data("{broken app settings".utf8).write(to: configurationURL, options: .atomic)
        }
        if damage == "power" || damage == "both" {
            try Data("[{broken power backup".utf8).write(to: powerStore.url, options: .atomic)
        }
        let originalConfigurationBytes = try Data(contentsOf: configurationURL)
        let originalPowerBytes = try Data(contentsOf: powerStore.url)
        let system = MockRecoverySystem()
        let pendingStore = FixtureRecoveryStore(directory: directory)
        let pending = PendingState(snapshot: system.original, sawLock: true)
        try pendingStore.save(pending)
        let engine = try SleepGuard(system: system, store: pendingStore)
        let pendingBytes = try Data(contentsOf: pendingStore.url)

        let settings = RuntimeSettings.load(configuration: { try configurationStore.load() }, preferences: {
            try PowerPreferencesManager(adapter: NoHardwarePowerAdapter(), store: powerStore)
        })
        try expect(!settings.ready && settings.issue != nil, "Damaged settings were declared ready")
        let brokenConfiguration = damage != "power"
        let brokenPower = damage == "power" || damage == "both"
        try expect((settings.configurationError != nil) == brokenConfiguration,
                   "Configuration failure was attributed to the wrong store")
        try expect((settings.preferencesError != nil) == brokenPower && (settings.preferences == nil) == brokenPower,
                   "Power backup failure was attributed to the wrong store")
        if brokenConfiguration {
            try expect(!settings.configuration.protectionEnabled && settings.configuration.protectionPaused,
                       "Configuration fallback enabled new protection")
        }
        try expect(engine.pending == pending && system.restores.isEmpty, "Settings loading changed pending recovery")
        do {
            try engine.recover(sessionVerified: false)
            throw CheckFailure(description: "Repair mode bypassed session verification")
        } catch SleepGuardError.sessionNotVerified { }
        let stillPendingBytes = try Data(contentsOf: pendingStore.url)
        try expect(stillPendingBytes == pendingBytes && system.restores.isEmpty,
                   "Unverified manual recovery changed the saved state")
        try engine.recover(sessionVerified: true)
        try expect(engine.pending == nil && system.restores == [system.original],
                   "Valid pending recovery depended on unrelated settings loading")
        let remaining = try pendingStore.load()
        try expect(remaining == nil, "Completed manual recovery retained pending data")
        let finalConfigurationBytes = try Data(contentsOf: configurationURL)
        let finalPowerBytes = try Data(contentsOf: powerStore.url)
        try expect(finalConfigurationBytes == originalConfigurationBytes && finalPowerBytes == originalPowerBytes,
                   "Repair mode overwrote damaged or future-version settings")
    }

    static func healthySettings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationStore = AppConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json"))
        let expected = AppConfiguration(existingInstallation: true)
        try configurationStore.save(expected)
        let powerStore = try JSONPowerPreferencesStore(directory: directory)
        try powerStore.save([])
        let beforeConfiguration = try Data(contentsOf: configurationStore.fileURL)
        let beforePower = try Data(contentsOf: powerStore.url)
        let settings = RuntimeSettings.load(configuration: { try configurationStore.load() }, preferences: {
            try PowerPreferencesManager(adapter: NoHardwarePowerAdapter(), store: powerStore)
        })
        try expect(settings.ready && settings.issue == nil && settings.configuration == expected && settings.preferences != nil,
                   "Healthy settings were unnecessarily disabled")
        let afterConfiguration = try Data(contentsOf: configurationStore.fileURL)
        let afterPower = try Data(contentsOf: powerStore.url)
        try expect(beforeConfiguration == afterConfiguration && beforePower == afterPower,
                   "Read-only settings initialization rewrote stored files")
    }

    static func failureLifetimes() throws {
        var failures = RuntimeFailures(startup: "startup", registration: "registration",
                                       operation: "operation", diagnostic: "diagnostic")
        try expect(failures.message == "startup\nregistration\noperation\ndiagnostic", "Failure display lost an error category")
        failures.diagnostic = nil
        try expect(failures.message == "startup\nregistration\noperation", "Successful refresh cleared a durable failure")
        failures.diagnostic = "new diagnostic"
        failures.diagnostic = nil
        try expect(failures.startup == "startup" && failures.operation == "operation" && failures.registration == "registration",
                   "Repeated diagnostic refresh changed another error lifetime")
        failures.operation = nil
        try expect(failures.message == "startup\nregistration", "Resolving an operation cleared startup or registration")
        failures.startup = nil; failures.registration = nil
        try expect(failures.message == nil, "Resolved failures left a stale error message")
    }

    static func startupLoginFallback(futureSchema: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json"))
        let bytes: Data
        if futureSchema {
            var configuration = AppConfiguration(existingInstallation: true, launchAtLogin: true)
            configuration.schemaVersion += 1
            bytes = try JSONEncoder().encode(configuration)
        } else { bytes = Data("{broken launch preference".utf8) }
        try bytes.write(to: store.fileURL, options: .atomic)
        let login = RuntimeLaunchPolicy.loginPreference(load: { try store.load() })
        try expect(!login, "Damaged settings prevented safe non-login startup selection")
        let preserved = try Data(contentsOf: store.fileURL)
        try expect(preserved == bytes, "Choosing repair startup overwrote damaged or future configuration")
    }

    static func healthyStartupLogin() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json"))
        for enabled in [true, false] {
            try store.save(AppConfiguration(existingInstallation: true, launchAtLogin: enabled))
            let before = try Data(contentsOf: store.fileURL)
            let login = RuntimeLaunchPolicy.loginPreference(load: { try store.load() })
            let after = try Data(contentsOf: store.fileURL)
            try expect(login == enabled && before == after, "Startup changed or ignored the saved login preference")
        }
    }

    static func refreshCadence() throws {
        try expect(RuntimeRefreshCadence.interval(pending: false, dashboardVisible: false) == 60,
                   "Background idle diagnostics did not use the slower interval")
        for (pending, visible) in [(true, false), (false, true), (true, true)] {
            try expect(RuntimeRefreshCadence.interval(pending: pending, dashboardVisible: visible) == 10,
                       "Pending recovery or visible dashboard lost the responsive interval")
        }
    }

    static let screens = [
        HotCornerScreen(id: "primary", x: 0, y: 0, width: 100, height: 100),
        HotCornerScreen(id: "secondary", x: -200, y: 0, width: 100, height: 100)
    ]
    static let corners = HotCorner.allCases.map { HotCornerConfiguration(corner: $0, action: 10) }

    static func pointerTransitions() throws {
        var filter = HotCornerPointerFilter()
        let tracker = HotCornerEntryTracker()
        var submissions = 0
        func observe(_ point: HotCornerPoint, at time: TimeInterval) -> Bool {
            guard filter.shouldSubmit(point: point, screens: screens) else { return false }
            submissions += 1
            tracker.observe(point: point, screens: screens, modifiers: 0, configurations: corners, at: time)
            return true
        }
        for index in 0..<10_000 {
            _ = observe(HotCornerPoint(x: Double(10 + index % 80), y: Double(10 + (index / 80) % 80)), at: 0)
        }
        try expect(submissions == 1 && tracker.recentEntry(at: 0) == nil,
                   "Ordinary pointer motion flooded the queue or created a corner entry")
        try expect(observe(HotCornerPoint(x: 0, y: 99), at: 1), "Primary corner entry was dropped")
        try expect(tracker.recentEntry(at: 1)?.corner == .topLeft && tracker.recentEntry(at: 1)?.enteredAt == 1,
                   "Primary entry lost its timestamp or corner")
        try expect(!observe(HotCornerPoint(x: 1, y: 98), at: 1.5), "Parked corner motion was resubmitted")
        try expect(tracker.recentEntry(at: 1.5)?.enteredAt == 1, "Parked pointer refreshed the entry timestamp")
        try expect(observe(HotCornerPoint(x: 20, y: 70), at: 2), "Corner exit was dropped")
        try expect(observe(HotCornerPoint(x: 0, y: 99), at: 3), "Corner reentry was dropped")
        try expect(tracker.recentEntry(at: 3)?.enteredAt == 3, "Reentry retained stale evidence")
        try expect(observe(HotCornerPoint(x: -200, y: 99), at: 4), "Same corner on a secondary screen was coalesced away")
        try expect(tracker.recentEntry(at: 4)?.screenID == "secondary" && tracker.recentEntry(at: 4)?.enteredAt == 4,
                   "Secondary-screen entry lost screen identity or timestamp")
        try expect(!observe(HotCornerPoint(x: -199, y: 98), at: 4.1), "Secondary parked motion was resubmitted")
        try expect(observe(HotCornerPoint(x: 300, y: 300), at: 4.2), "Leaving all screens lost the corner exit")
        try expect(!observe(HotCornerPoint(x: 301, y: 300), at: 4.3), "Repeated off-screen movement was resubmitted")
        try expect(observe(HotCornerPoint(x: -101, y: 0), at: 5), "Secondary bottom-right entry was dropped")
        try expect(tracker.recentEntry(at: 5)?.corner == .bottomRight && tracker.recentEntry(at: 5)?.screenID == "secondary",
                   "Negative-coordinate screen edges were misidentified")
        try expect(submissions == 7, "Corner filter emitted extra movement submissions")
    }

    static func parkedStartup() throws {
        var filter = HotCornerPointerFilter()
        let tracker = HotCornerEntryTracker()
        let corner = HotCornerPoint(x: 0, y: 99)
        try expect(filter.shouldSubmit(point: corner, screens: screens), "Initial corner occupancy was not seeded")
        tracker.observe(point: corner, screens: screens, modifiers: 0, configurations: corners, at: 0)
        try expect(tracker.recentEntry(at: 0) == nil, "A startup pointer created false entry evidence")
        try expect(!filter.shouldSubmit(point: corner, screens: screens), "Parked startup was resubmitted")
        let outside = HotCornerPoint(x: 50, y: 50)
        try expect(filter.shouldSubmit(point: outside, screens: screens), "First corner departure was lost")
        tracker.observe(point: outside, screens: screens, modifiers: 0, configurations: corners, at: 1)
        try expect(filter.shouldSubmit(point: corner, screens: screens), "First genuine reentry was lost")
        tracker.observe(point: corner, screens: screens, modifiers: 0, configurations: corners, at: 2)
        try expect(tracker.recentEntry(at: 2)?.enteredAt == 2, "Genuine entry after startup was not recorded")
    }

    static func updatedCornerConfiguration() throws {
        var filter = HotCornerPointerFilter()
        let classifier = SleepOriginClassifier()
        let oldCachedConfiguration = HotCorners.parse([:])
        let outside = HotCornerPoint(x: 50, y: 50)
        if filter.shouldSubmit(point: outside, screens: screens) {
            classifier.corners.observe(point: outside, screens: screens, modifiers: 0,
                configurations: oldCachedConfiguration, at: 0)
        }
        // The user changes macOS settings between periodic diagnostics. The
        // transition handler supplies fresh values, rather than the old cache.
        let currentConfiguration = HotCorners.parse(["wvous-tl-corner": NSNumber(value: 10)])
        let entry = HotCornerPoint(x: 0, y: 99)
        try expect(filter.shouldSubmit(point: entry, screens: screens), "New corner entry was filtered away")
        classifier.corners.observe(point: entry, screens: screens, modifiers: 0,
            configurations: currentConfiguration, at: 1)
        let revision = classifier.corners.configurationRevision
        // Actual display sleep revalidates the same current configuration.
        classifier.corners.updateConfigurations(currentConfiguration)
        let origin = classifier.classify(.display, at: 1.2, lidIsClosed: false)
        try expect(origin == .hotCorner(.topLeft) && classifier.corners.configurationRevision == revision,
                   "Fresh corner settings invalidated the matching entry at the sleep boundary")
        let changedAgain = HotCorners.parse(["wvous-tl-corner": NSNumber(value: 13)])
        classifier.corners.updateConfigurations(changedAgain)
        try expect(classifier.classify(.display, at: 1.3, lidIsClosed: false) == .unknown,
                   "A later non-sleep corner action retained stale sleep evidence")
    }

    static func queuedUnlockInvalidation(newCycle: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = MockRecoverySystem()
        let engine = try SleepGuard(system: system, store: FixtureRecoveryStore(directory: directory))
        let fence = UnlockEventFence()
        let queue = DispatchQueue(label: "SleepSeal.runtime-reliability.unlock-test")
        let oldGate = try queue.sync { () throws -> UUID in
            try engine.beforeSleep(); try engine.didLock()
            if !newCycle { try engine.observedUnlock(gateID: engine.pending!.id, sessionVerified: false) }
            return engine.pending!.id
        }
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let result = QueuedUnlockResult()
        queue.async {
            started.signal()
            if release.wait(timeout: .now() + 5) != .success {
                result.error = CheckFailure(description: "Simulated queue backlog was never released")
            }
        }
        try expect(started.wait(timeout: .now() + 2) == .success, "Queue backlog did not start")
        let staleToken = fence.capture()
        // The new notification invalidates at receipt, before either queued
        // handler can run. Its state update reaches the queue before unlock.
        fence.invalidate()
        queue.async {
            do {
                if newCycle { try engine.beforeSleep() }
                try engine.didLock()
            } catch { result.error = error }
        }
        queue.async {
            do {
                result.gateAtExecution = engine.pending?.id
                guard fence.accepts(staleToken) else { result.rejected = true; return }
                if let gate = engine.pending?.id { try engine.observedUnlock(gateID: gate, sessionVerified: true) }
            } catch { result.error = error }
        }
        release.signal()
        try queue.sync {
            if let error = result.error { throw error }
            try expect(result.rejected && !fence.accepts(staleToken), "Queued unlock survived notification invalidation")
            try expect((result.gateAtExecution != oldGate) == newCycle,
                       "Queue did not exercise the expected new-gate or same-gate race")
            try expect(engine.pending != nil && engine.pending?.restorationAuthorized == false
                       && engine.pending?.unlockCandidate == nil && system.restores.isEmpty,
                       "Stale queued unlock authorized or restored the active cycle")
            let currentToken = fence.capture()
            try expect(fence.accepts(currentToken), "Current notification token was rejected")
            if let gate = engine.pending?.id, fence.accepts(currentToken) {
                try engine.observedUnlock(gateID: gate, sessionVerified: true)
            }
            try expect(engine.pending == nil && system.restores == [system.original],
                       "A legitimate current unlock could not restore the active cycle")
        }
    }
}
