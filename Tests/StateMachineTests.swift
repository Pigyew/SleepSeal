import Foundation

private enum StubFailure: Error, Equatable {
    case capture, save, suppress, restore, clear, load
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class Trace {
    var events: [String] = []
}

private final class FakeSystem: GuardSystem {
    var snapshot: Snapshot
    let trace: Trace
    var captureFailure = false
    var suppressFailure = false
    var restoreFailure = false
    var captureCount = 0
    var suppressions: [Snapshot] = []
    var restorations: [Snapshot] = []

    init(snapshot: Snapshot, trace: Trace = Trace()) {
        self.snapshot = snapshot
        self.trace = trace
    }

    func capture() throws -> Snapshot {
        trace.events.append("capture")
        captureCount += 1
        if captureFailure { throw StubFailure.capture }
        return snapshot
    }

    func suppress(_ snapshot: Snapshot) throws {
        trace.events.append("suppress")
        suppressions.append(snapshot)
        if suppressFailure { throw StubFailure.suppress }
    }

    func restore(_ snapshot: Snapshot) throws {
        trace.events.append("restore")
        restorations.append(snapshot)
        if restoreFailure { throw StubFailure.restore }
    }
}

private final class FakeStore: GuardStore {
    var state: PendingState?
    let trace: Trace
    var saveFailure = false
    var clearFailure = false
    var loadFailure = false
    var saveCount = 0
    var clearCount = 0

    init(state: PendingState? = nil, trace: Trace = Trace()) {
        self.state = state
        self.trace = trace
    }

    func load() throws -> PendingState? {
        trace.events.append("load")
        if loadFailure { throw StubFailure.load }
        return state
    }

    func save(_ state: PendingState) throws {
        trace.events.append("save")
        saveCount += 1
        if saveFailure { throw StubFailure.save }
        self.state = state
    }

    func clear() throws {
        trace.events.append("clear")
        clearCount += 1
        if clearFailure { throw StubFailure.clear }
        state = nil
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func expectFailure(_ failure: StubFailure, _ action: () throws -> Void) throws {
    do {
        try action()
    } catch let caught as StubFailure {
        try expect(caught == failure, "Expected \(failure), received \(caught)")
        return
    }
    throw TestFailure(description: "Expected \(failure) to be thrown")
}

private func sampleSnapshot(_ enabled: Bool = true) -> Snapshot {
    Snapshot(
        wifi: ["en0": enabled, "en7": false],
        bluetooth: enabled,
        power: [
            PowerValue(scope: "-b", key: "lowpowermode", value: enabled ? 0 : 1),
            PowerValue(scope: "-c", key: "powernap", value: 1)
        ]
    )
}

@main
struct StateMachineTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("snapshot is saved before suppression", durableBeforeSuppression),
            ("wake reasserts without restoring", wakeDoesNotRestore),
            ("nested sleeps preserve original snapshot", nestedSleepKeepsOriginal),
            ("unlock requires a recorded lock and verification", unlockRequiresBothChecks),
            ("lock then verified unlock restores and clears", verifiedUnlockRestores),
            ("restart loads recovery record without mutations", restartRetainsPending),
            ("save failure prevents all system changes", saveFailurePreventsSuppression),
            ("capture failure leaves no pending state", captureFailureLeavesNoPending),
            ("suppression failure retains recovery record", suppressionFailureRetainsPending),
            ("failed lock save does not authorize unlock", lockSaveFailureRetainsEligibility),
            ("restore failure retains state for retry", restoreFailureRetainsPending),
            ("clear failure retains state for idempotent retry", clearFailureRetainsPending),
            ("authorized partial restore retries never suppress", authorizedRetriesDoNotSuppress),
            ("locked reconciliation suppresses authorized state", lockedReconciliationSuppresses),
            ("new sleep invalidates prior authorization and ID", newSleepInvalidatesAuthorization),
            ("authorization save failure prevents restoration", authorizationSaveFailurePreventsRestore),
            ("new sleep save failure preserves prior gate", newSleepSaveFailurePreservesGate),
            ("manual recovery rejects locked sessions", recoveryRequiresVerification),
            ("manual recovery handles missing lock event", manualRecoveryWithoutLock),
            ("idle events make no system changes", idleEventsAreNoOps),
            ("load failure propagates without writes", loadFailureDoesNotWrite),
            ("snapshot and pending state round trip", codableRoundTrip)
        ]
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
        print("\(tests.count) state machine tests passed.")
    }

    private static func durableBeforeSuppression() throws {
        let trace = Trace()
        let original = sampleSnapshot()
        let system = FakeSystem(snapshot: original, trace: trace)
        let store = FakeStore(trace: trace)
        let guarder = try SleepGuard(system: system, store: store)
        try expect(trace.events == ["load"], "Initialization must only load")
        try guarder.beforeSleep()
        try expect(trace.events == ["load", "capture", "save", "suppress"], "Unsafe transition order")
        try expect(guarder.pending?.snapshot == original && guarder.pending?.sawLock == false, "Missing in-memory record")
        try expect(guarder.pending?.restorationAuthorized == false, "New sleep was already authorized to restore")
        try expect(store.state == guarder.pending, "Missing durable record")
    }

    private static func wakeDoesNotRestore() throws {
        let system = FakeSystem(snapshot: sampleSnapshot())
        let store = FakeStore()
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.beforeSleep()
        try guarder.didLock()
        try guarder.didWake()
        try guarder.didWake()
        try expect(system.restorations.isEmpty, "A wake restored settings")
        try expect(system.suppressions.count == 3, "Every wake must reassert suppression")
        try expect(guarder.pending != nil && store.state != nil, "Wake discarded recovery data")
    }

    private static func nestedSleepKeepsOriginal() throws {
        let original = sampleSnapshot()
        let system = FakeSystem(snapshot: original)
        let store = FakeStore()
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.beforeSleep()
        try guarder.didLock()
        let previousID = guarder.pending?.id
        system.snapshot = sampleSnapshot(false)
        try guarder.beforeSleep()
        try expect(system.captureCount == 1, "Nested sleep recaptured suppressed settings")
        try expect(store.saveCount == 3, "Nested sleep did not persist its new unlock gate")
        try expect(guarder.pending?.snapshot == original, "Nested sleep overwrote original settings")
        try expect(guarder.pending?.id != previousID, "Nested sleep reused the previous unlock gate")
        try expect(guarder.pending?.sawLock == false && guarder.pending?.restorationAuthorized == false, "Nested sleep retained prior eligibility")
        try expect(system.suppressions == [original, original], "Nested sleep used a different snapshot")
    }

    private static func unlockRequiresBothChecks() throws {
        let system = FakeSystem(snapshot: sampleSnapshot())
        let store = FakeStore()
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.beforeSleep()
        try guarder.didUnlock(sessionVerified: true)
        try expect(system.restorations.isEmpty, "Unlock without lock evidence restored settings")
        try guarder.didLock()
        try guarder.didUnlock(sessionVerified: false)
        try expect(system.restorations.isEmpty, "Unverified unlock restored settings")
        try expect(store.clearCount == 0, "Blocked unlock cleared the recovery record")
    }

    private static func verifiedUnlockRestores() throws {
        let original = sampleSnapshot()
        let trace = Trace()
        let system = FakeSystem(snapshot: original, trace: trace)
        let store = FakeStore(trace: trace)
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.beforeSleep()
        try guarder.didLock()
        try guarder.didUnlock(sessionVerified: true)
        try expect(system.restorations == [original], "Did not restore original settings")
        try expect(guarder.pending == nil && store.state == nil, "Successful recovery retained state")
        try expect(Array(trace.events.suffix(3)) == ["save", "restore", "clear"], "Authorization must be saved before restoration and clear")
        try guarder.didUnlock(sessionVerified: true)
        try expect(system.restorations.count == 1, "Duplicate unlock restored twice")
    }

    private static func restartRetainsPending() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: true)
        let trace = Trace()
        let system = FakeSystem(snapshot: sampleSnapshot(false), trace: trace)
        let store = FakeStore(state: original, trace: trace)
        let guarder = try SleepGuard(system: system, store: store)
        try expect(guarder.pending == original, "Restart lost pending settings")
        try expect(trace.events == ["load"], "Initialization changed system state")
        try guarder.reassert()
        try expect(system.suppressions == [original.snapshot], "Restart reassert used current settings")
        try expect(store.saveCount == 0, "Reassert overwrote saved settings")
    }

    private static func saveFailurePreventsSuppression() throws {
        let system = FakeSystem(snapshot: sampleSnapshot())
        let store = FakeStore()
        store.saveFailure = true
        let guarder = try SleepGuard(system: system, store: store)
        try expectFailure(.save) { try guarder.beforeSleep() }
        try expect(system.suppressions.isEmpty && system.restorations.isEmpty, "Save failure changed settings")
        try expect(guarder.pending == nil && store.state == nil, "Save failure created pending state")
        store.saveFailure = false
        try guarder.beforeSleep()
        try expect(system.suppressions.count == 1, "Retry failed to suppress after persistence recovered")
    }

    private static func captureFailureLeavesNoPending() throws {
        let system = FakeSystem(snapshot: sampleSnapshot())
        system.captureFailure = true
        let store = FakeStore()
        let guarder = try SleepGuard(system: system, store: store)
        try expectFailure(.capture) { try guarder.beforeSleep() }
        try expect(guarder.pending == nil && store.saveCount == 0, "Failed capture was persisted")
        try expect(system.suppressions.isEmpty, "Failed capture changed settings")
    }

    private static func suppressionFailureRetainsPending() throws {
        let original = sampleSnapshot()
        let system = FakeSystem(snapshot: original)
        system.suppressFailure = true
        let store = FakeStore()
        let guarder = try SleepGuard(system: system, store: store)
        try expectFailure(.suppress) { try guarder.beforeSleep() }
        try expect(guarder.pending?.snapshot == original && guarder.pending?.sawLock == false, "Suppression failure lost original snapshot")
        try expect(guarder.pending != nil && store.state == guarder.pending, "Suppression failure lost durable recovery record")
        system.suppressFailure = false
        try guarder.reassert()
        try expect(system.captureCount == 1 && store.saveCount == 1, "Reassert recaptured or rewrote settings")
    }

    private static func lockSaveFailureRetainsEligibility() throws {
        let system = FakeSystem(snapshot: sampleSnapshot())
        let store = FakeStore()
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.beforeSleep()
        store.saveFailure = true
        try expectFailure(.save) { try guarder.didLock() }
        try expect(guarder.pending?.sawLock == false && store.state?.sawLock == false, "Failed lock save granted eligibility")
        try guarder.didUnlock(sessionVerified: true)
        try expect(system.restorations.isEmpty, "Failed lock save allowed restoration")
    }

    private static func restoreFailureRetainsPending() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: true)
        let system = FakeSystem(snapshot: original.snapshot)
        system.restoreFailure = true
        let store = FakeStore(state: original)
        let guarder = try SleepGuard(system: system, store: store)
        try expectFailure(.restore) { try guarder.didUnlock(sessionVerified: true) }
        var authorized = original
        authorized.restorationAuthorized = true
        try expect(guarder.pending == authorized && store.state == authorized, "Restore failure discarded recovery record or authorization")
        try expect(store.clearCount == 0, "Failed restore attempted to clear state")
        system.restoreFailure = false
        try guarder.didUnlock(sessionVerified: true)
        try expect(guarder.pending == nil && system.restorations.count == 2, "Restore retry did not complete")
    }

    private static func clearFailureRetainsPending() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: true)
        let system = FakeSystem(snapshot: original.snapshot)
        let store = FakeStore(state: original)
        store.clearFailure = true
        let guarder = try SleepGuard(system: system, store: store)
        try expectFailure(.clear) { try guarder.didUnlock(sessionVerified: true) }
        var authorized = original
        authorized.restorationAuthorized = true
        try expect(guarder.pending == authorized && store.state == authorized, "Clear failure lost recovery record or authorization")
        store.clearFailure = false
        try guarder.didUnlock(sessionVerified: true)
        try expect(system.restorations == [original.snapshot, original.snapshot], "Retry did not repeat the same restoration")
        try expect(guarder.pending == nil && store.state == nil, "Clear retry did not complete")
    }

    private static func authorizedRetriesDoNotSuppress() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: true)
        let system = FakeSystem(snapshot: original.snapshot)
        system.restoreFailure = true
        let store = FakeStore(state: original)
        let guarder = try SleepGuard(system: system, store: store)
        // The fake records restoration before failing, representing a partial
        // system write followed by failure of a later restoration step.
        try expectFailure(.restore) { try guarder.didUnlock(sessionVerified: true) }
        try expect(guarder.pending?.restorationAuthorized == true, "Partial restore lost authorization")
        try expectFailure(.restore) { try guarder.reconcile(sessionVerified: true) }
        try expect(system.suppressions.isEmpty, "Timer disabled settings after an authorized partial restore")
        try expect(store.saveCount == 1, "Authorized retry rewrote the authorization record")
        system.restoreFailure = false
        try guarder.reconcile(sessionVerified: true)
        try expect(system.restorations == [original.snapshot, original.snapshot, original.snapshot], "Retry did not restore the original snapshot")
        try expect(system.suppressions.isEmpty && guarder.pending == nil, "Authorized retries suppressed settings or failed to complete")
    }

    private static func lockedReconciliationSuppresses() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: false, restorationAuthorized: true)
        let system = FakeSystem(snapshot: original.snapshot)
        let store = FakeStore(state: original)
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.didLock()
        try expect(guarder.pending?.restorationAuthorized == true, "Lock revoked durable restoration authorization")
        try guarder.reconcile(sessionVerified: false)
        try expect(system.suppressions == [original.snapshot], "Locked reconciliation failed to suppress")
        try expect(system.restorations.isEmpty, "Locked reconciliation restored settings")
        try expect(guarder.pending?.id == original.id, "Lock changed the sleep gate")
        try guarder.reconcile(sessionVerified: true)
        try expect(system.restorations == [original.snapshot] && guarder.pending == nil, "Verified retry did not finish authorized restoration")
    }

    private static func newSleepInvalidatesAuthorization() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: true, restorationAuthorized: true)
        let trace = Trace()
        let system = FakeSystem(snapshot: sampleSnapshot(false), trace: trace)
        let store = FakeStore(state: original, trace: trace)
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.beforeSleep()
        try expect(guarder.pending?.id != original.id, "New sleep retained the old unlock ID")
        try expect(guarder.pending?.sawLock == false && guarder.pending?.restorationAuthorized == false, "New sleep retained authorization")
        try expect(guarder.pending?.snapshot == original.snapshot && store.state == guarder.pending, "New gate lost original saved settings")
        try expect(trace.events == ["load", "save", "suppress"], "New gate was not persisted before suppression")
        try guarder.reconcile(sessionVerified: true)
        try guarder.didUnlock(sessionVerified: true)
        try expect(system.restorations.isEmpty, "A new sleep restored using the previous authorization")
        try expect(system.suppressions == [original.snapshot, original.snapshot], "New unauthorised gate did not stay suppressed")
    }

    private static func authorizationSaveFailurePreventsRestore() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: true)
        let system = FakeSystem(snapshot: original.snapshot)
        let store = FakeStore(state: original)
        store.saveFailure = true
        let guarder = try SleepGuard(system: system, store: store)
        try expectFailure(.save) { try guarder.didUnlock(sessionVerified: true) }
        try expect(guarder.pending == original && store.state == original, "Failed save authorized restoration")
        try expect(system.restorations.isEmpty, "Restoration ran before authorization was durable")
        try guarder.reconcile(sessionVerified: true)
        try expect(system.suppressions == [original.snapshot] && system.restorations.isEmpty, "Reconcile bypassed a failed authorization save")
        try expectFailure(.save) { try guarder.recover(sessionVerified: true) }
        try expect(system.restorations.isEmpty && guarder.pending == original, "Manual recovery bypassed authorization persistence")
    }

    private static func newSleepSaveFailurePreservesGate() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: true, restorationAuthorized: true)
        let system = FakeSystem(snapshot: original.snapshot)
        let store = FakeStore(state: original)
        store.saveFailure = true
        let guarder = try SleepGuard(system: system, store: store)
        try expectFailure(.save) { try guarder.beforeSleep() }
        try expect(guarder.pending == original && store.state == original, "Failed new gate save changed pending state")
        try expect(system.captureCount == 0 && system.suppressions.isEmpty, "Failed gate save changed settings")
    }

    private static func recoveryRequiresVerification() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: true)
        let system = FakeSystem(snapshot: original.snapshot)
        let store = FakeStore(state: original)
        let guarder = try SleepGuard(system: system, store: store)
        do {
            try guarder.recover(sessionVerified: false)
            throw TestFailure(description: "Unverified recovery was accepted")
        } catch SleepGuardError.sessionNotVerified {
            // Expected: manual recovery must report refusal to the caller.
        }
        try expect(system.restorations.isEmpty && store.clearCount == 0, "Locked recovery changed settings")
        try expect(guarder.pending == original && store.state == original, "Locked recovery lost state")
    }

    private static func manualRecoveryWithoutLock() throws {
        let original = PendingState(snapshot: sampleSnapshot(), sawLock: false)
        let trace = Trace()
        let system = FakeSystem(snapshot: original.snapshot, trace: trace)
        let store = FakeStore(state: original, trace: trace)
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.recover(sessionVerified: true)
        try expect(system.restorations == [original.snapshot], "Verified manual recovery did not restore")
        try expect(trace.events == ["load", "save", "restore", "clear"], "Manual recovery did not persist authorization first")
        try expect(guarder.pending == nil && store.state == nil, "Manual recovery retained state")
    }

    private static func idleEventsAreNoOps() throws {
        let trace = Trace()
        let system = FakeSystem(snapshot: sampleSnapshot(), trace: trace)
        let store = FakeStore(trace: trace)
        let guarder = try SleepGuard(system: system, store: store)
        try guarder.didWake()
        try guarder.didLock()
        try guarder.didUnlock(sessionVerified: true)
        try guarder.reassert()
        try guarder.reconcile(sessionVerified: false)
        try guarder.reconcile(sessionVerified: true)
        try guarder.recover(sessionVerified: true)
        try expect(trace.events == ["load"], "Idle event caused a write or capture")
    }

    private static func loadFailureDoesNotWrite() throws {
        let trace = Trace()
        let system = FakeSystem(snapshot: sampleSnapshot(), trace: trace)
        let store = FakeStore(trace: trace)
        store.loadFailure = true
        try expectFailure(.load) { _ = try SleepGuard(system: system, store: store) }
        try expect(trace.events == ["load"], "Initialization failure performed another operation")
    }

    private static func codableRoundTrip() throws {
        let state = PendingState(snapshot: sampleSnapshot(), sawLock: true)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PendingState.self, from: data)
        try expect(state == decoded, "Saved state did not round trip")
        let noBluetooth = Snapshot(wifi: [:], bluetooth: nil, power: [])
        let emptyData = try JSONEncoder().encode(noBluetooth)
        let emptyDecoded = try JSONDecoder().decode(Snapshot.self, from: emptyData)
        try expect(emptyDecoded == noBluetooth, "Unknown Bluetooth state did not round trip")
    }
}
