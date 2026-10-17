import Foundation

private enum Failure: Error { case capture, suppress, restore }
private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(description: message) }
}
private final class CycleSystem: GuardSystem {
    var state = Snapshot(wifi: ["en0": true], bluetooth: true,
                         power: [PowerValue(scope: "-b", key: "powermode", value: 0)])
    var captures = 0
    var suppressions: [Snapshot] = []
    var restorations: [Snapshot] = []
    var failCapture = false
    var failSuppress = false
    var failRestore = false
    func capture() throws -> Snapshot {
        captures += 1
        if failCapture { throw Failure.capture }
        return state
    }
    func suppress(_ snapshot: Snapshot) throws {
        suppressions.append(snapshot)
        if failSuppress { throw Failure.suppress }
    }
    func restore(_ snapshot: Snapshot) throws {
        restorations.append(snapshot)
        if failRestore { throw Failure.restore }
    }
}
private final class CycleStore: GuardStore {
    var state: PendingState?
    func load() throws -> PendingState? { state }
    func save(_ state: PendingState) throws { self.state = state }
    func clear() throws { state = nil }
}
private struct Fixture {
    let system: CycleSystem
    let store: CycleStore
    let engine: SleepGuard
    let transitions: SleepTransitions
    let coordinator = ProtectionCoordinator()
    init() throws {
        system = CycleSystem(); store = CycleStore()
        engine = try SleepGuard(system: system, store: store)
        transitions = SleepTransitions(engine: engine)
    }
    @discardableResult func sleep(_ source: SleepSource, origin: SleepOrigin, policy: TriggerPolicy,
                                  enabled: Bool = true, ready: Bool = true, locked: Bool = false) throws -> ProtectionCycleDecision {
        let decision = coordinator.decide(origin: origin, policy: policy, enabled: enabled,
                                           ready: ready, pending: engine.pending != nil)
        if decision.shouldAttemptProtection { try transitions.sleep(source, sessionLocked: locked) }
        return decision
    }
    func wake(_ source: SleepSource, verified: Bool = false) throws {
        coordinator.didWake()
        try transitions.wake(source, sessionVerified: verified)
    }
}

@main struct RuntimeCycleTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("sixteen trigger combinations control real capture and suppression", triggerMatrix),
            ("unknown custom sleep keeps radios untouched", unknownCustom),
            ("later actual sleep can clarify a skipped display", clarifySkippedDisplay),
            ("rule edits apply after a wake boundary", rulesChangeNextCycle),
            ("active snapshot survives rule edits and overlapping sleep", activeSnapshotSurvives),
            ("canceled idle proposals never capture settings", canceledIdle),
            ("failed manual requests never capture settings", failedManual),
            ("missing permissions keep the system unchanged", missingPermissions),
            ("partial suppression retains recovery across source overlap", partialSuppression),
            ("wake alone cannot restore a protected cycle", wakeNotUnlock),
            ("pause restoration failure retains record and permits retry", pauseFailure),
            ("successful control freeze blocks a new protection cycle", freezeThenResume),
            ("pending recovery remains protected during control freeze", pendingDuringFreeze),
            ("persistent timer preferences survive transient recovery", persistentPreferences)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) runtime cycle scenarios passed using real core state machines and mocked system adapters.")
    }

    static func triggerMatrix() throws {
        let cases = ProtectionTrigger.allCases
        let origins: [SleepOrigin] = [.manual, .lid, .hotCorner(.topLeft), .idle]
        for mask in 0..<16 {
            let selected = Set(cases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            for (index, origin) in origins.enumerated() {
                let f = try Fixture()
                let policy = TriggerPolicy(mode: .custom, sources: selected)
                let result = try f.sleep(.system, origin: origin, policy: policy)
                let allowed = selected.contains(cases[index])
                try expect(result.shouldAttemptProtection == allowed, "Wrong runtime decision for \(mask)/\(origin)")
                try expect(f.system.captures == (allowed ? 1 : 0) && f.system.suppressions.count == (allowed ? 1 : 0),
                           "Unexpected hardware-adapter work for \(mask)/\(origin)")
                try expect((f.store.state != nil) == allowed, "Recovery-record decision differed from protection")
            }
        }
    }

    static func unknownCustom() throws {
        let f = try Fixture()
        let policy = TriggerPolicy(mode: .custom)
        let result = try f.sleep(.display, origin: .unknown, policy: policy)
        try expect(!result.shouldAttemptProtection && result.policyDecision.reason == .unknownSource,
                   "Unknown source was not explained as skipped")
        try expect(f.system.captures == 0 && f.system.suppressions.isEmpty && f.store.state == nil,
                   "Unknown custom source touched a radio or record")
    }

    static func clarifySkippedDisplay() throws {
        let f = try Fixture()
        let lidOnly = TriggerPolicy(mode: .custom, sources: [.lid])
        try f.sleep(.display, origin: .unknown, policy: lidOnly)
        let result = try f.sleep(.system, origin: .lid, policy: lidOnly, locked: true)
        try expect(result.origin == .lid && f.system.captures == 1 && f.engine.pending?.sawLock == true,
                   "Actual lid sleep failed to clarify the earlier display event")
    }

    static func rulesChangeNextCycle() throws {
        let f = try Fixture()
        let none = TriggerPolicy(mode: .custom, sources: [])
        try f.sleep(.display, origin: .unknown, policy: none)
        let sameCycle = try f.sleep(.system, origin: .lid, policy: TriggerPolicy())
        try expect(!sameCycle.shouldAttemptProtection && f.system.captures == 0,
                   "Rule change rewrote an already-started sleep cycle")
        try f.wake(.system)
        let next = try f.sleep(.system, origin: .unknown, policy: TriggerPolicy())
        try expect(next.shouldAttemptProtection && f.system.captures == 1, "Rule change did not apply to the next cycle")
    }

    static func activeSnapshotSurvives() throws {
        let f = try Fixture()
        let original = f.system.state
        try f.sleep(.display, origin: .hotCorner(.topRight), policy: TriggerPolicy(), locked: true)
        let gate = f.engine.pending?.id
        f.system.state = Snapshot(wifi: ["en0": false], bluetooth: false, power: [])
        let later = try f.sleep(.system, origin: .idle, policy: TriggerPolicy(mode: .custom, sources: []), enabled: false)
        try expect(later.shouldAttemptProtection && later.origin == .hotCorner(.topRight), "Active origin or pending recovery was overwritten")
        try expect(f.engine.pending?.snapshot == original && f.engine.pending?.id == gate && f.system.captures == 1,
                   "Overlapping event recaptured suppressed settings or replaced the gate")
    }

    static func canceledIdle() throws {
        let f = try Fixture()
        let classifier = SleepOriginClassifier()
        classifier.recordIdleSleepProposal(at: 10)
        classifier.cancelIdleSleepProposal()
        // No system sleep notification means no coordinator call or capture.
        try expect(f.system.captures == 0 && f.engine.pending == nil, "Proposal itself touched the system")
        let origin = classifier.classify(.system, at: 11, lidIsClosed: false)
        try f.sleep(.system, origin: origin, policy: TriggerPolicy(mode: .custom, sources: [.idle]))
        try expect(f.system.captures == 0 && f.engine.pending == nil, "Canceled proposal enabled an unrelated sleep")
    }

    static func failedManual() throws {
        let f = try Fixture()
        let classifier = SleepOriginClassifier()
        let token = classifier.recordManualRequest(at: 10)
        classifier.completeManualRequest(token, accepted: false)
        let origin = classifier.classify(.system, at: 10.1, lidIsClosed: false)
        try f.sleep(.system, origin: origin, policy: TriggerPolicy(mode: .custom, sources: [.manual]))
        try expect(f.system.captures == 0 && f.system.suppressions.isEmpty,
                   "A rejected manual request started protection")
    }

    static func missingPermissions() throws {
        let f = try Fixture()
        let result = try f.sleep(.system, origin: .manual, policy: TriggerPolicy(), ready: false)
        try expect(result.permissionsMissing && !result.shouldAttemptProtection, "Missing permission was not represented")
        try expect(f.system.captures == 0 && f.store.state == nil, "Missing permission allowed partial protection")
    }

    static func partialSuppression() throws {
        let f = try Fixture()
        let original = f.system.state
        f.system.failSuppress = true
        do { try f.sleep(.display, origin: .idle, policy: TriggerPolicy(), locked: true); throw CheckFailure(description: "Expected suppression failure") }
        catch Failure.suppress { }
        let id = f.engine.pending?.id
        f.system.failSuppress = false
        try f.sleep(.system, origin: .unknown, policy: TriggerPolicy(mode: .custom, sources: []), ready: false)
        try expect(f.system.captures == 1 && f.engine.pending?.id == id && f.store.state?.snapshot == original,
                   "Partial failure lost recovery state on overlapping sleep")
        try f.engine.observedUnlock(gateID: id!, sessionVerified: true)
        try expect(f.system.restorations == [original] && f.engine.pending == nil, "Partial failure could not recover")
    }

    static func wakeNotUnlock() throws {
        let f = try Fixture()
        try f.sleep(.display, origin: .unknown, policy: TriggerPolicy(), locked: true)
        try f.wake(.display, verified: true)
        try expect(f.system.restorations.isEmpty && f.engine.pending != nil, "Wake was treated as user authorization")
    }

    static func pauseFailure() throws {
        let f = try Fixture()
        try f.sleep(.system, origin: .manual, policy: TriggerPolicy())
        let original = f.engine.pending?.snapshot
        f.system.failRestore = true
        do {
            try f.coordinator.recover(freeze: true) { try f.engine.recover(sessionVerified: true) }
            throw CheckFailure(description: "Expected pause restoration failure")
        } catch Failure.restore { }
        try expect(!f.coordinator.isQuiescing && f.engine.pending?.snapshot == original && f.store.state != nil,
                   "Failed pause lost the recovery record or left the UI frozen")
        f.system.failRestore = false
        try f.coordinator.recover(freeze: true) { try f.engine.recover(sessionVerified: true) }
        try expect(f.coordinator.isQuiescing && f.engine.pending == nil, "Pause retry did not complete recovery before freezing")
    }

    static func freezeThenResume() throws {
        let f = try Fixture()
        try f.coordinator.recover(freeze: true) { try f.engine.recover(sessionVerified: true) }
        let frozen = try f.sleep(.system, origin: .manual, policy: TriggerPolicy())
        try expect(!frozen.shouldAttemptProtection && f.system.captures == 0, "A queued sleep raced successful quit/pause recovery")
        f.coordinator.resumeAfterFailedControl()
        let retried = try f.sleep(.system, origin: .manual, policy: TriggerPolicy())
        try expect(retried.shouldAttemptProtection && f.system.captures == 1, "Canceled control could not resume protection")
    }

    static func pendingDuringFreeze() throws {
        let f = try Fixture()
        try f.sleep(.display, origin: .idle, policy: TriggerPolicy())
        // A successful external control step can be frozen while its pending
        // record still exists. Suppression must continue until recovery clears it.
        f.coordinator.recover(freeze: true) { }
        let result = try f.sleep(.system, origin: .unknown, policy: TriggerPolicy(), enabled: false, ready: false)
        try expect(!result.requested && result.shouldAttemptProtection && f.system.suppressions.count == 2,
                   "Control freeze abandoned an existing pending snapshot")
    }

    static func persistentPreferences() throws {
        let f = try Fixture()
        let persistent = try PowerPreferencesManager(adapter: MemoryPreferencesAdapter(), store: MemoryPreferencesStore())
        let before = try persistent.read().value(source: .battery, key: .displaySleep)!
        _ = try persistent.apply([PowerPreferenceEdit(original: before, target: 25)], guardPending: false)
        try f.sleep(.system, origin: .manual, policy: TriggerPolicy())
        try f.engine.recover(sessionVerified: true)
        let after = try persistent.read().value(source: .battery, key: .displaySleep)?.value
        try expect(after == 25, "Transient unlock recovery undid persistent timer settings")
    }
}

private final class MemoryPreferencesAdapter: PowerPreferencesAdapter {
    var values = [PowerPreferenceValue(source: .battery, key: .displaySleep, value: 10)]
    func read() throws -> PowerPreferencesSnapshot {
        PowerPreferencesSnapshot(values: values, supportedEnergyModes: [:])
    }
    func write(_ value: PowerPreferenceValue, restoring: Bool) throws {
        values.removeAll { $0.id == value.id }; values.append(value)
    }
}
private final class MemoryPreferencesStore: PowerPreferencesStore {
    var backups: [PowerPreferenceBackup] = []
    func load() throws -> [PowerPreferenceBackup] { backups }
    func save(_ backups: [PowerPreferenceBackup]) throws { self.backups = backups }
}
