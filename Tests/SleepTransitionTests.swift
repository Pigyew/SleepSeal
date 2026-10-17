import Foundation

private enum StubFailure: Error, Equatable {
    case capture, save, suppress, restore
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class FakeSystem: GuardSystem {
    var snapshot = Snapshot(
        wifi: ["en0": true, "en7": false],
        bluetooth: true,
        power: [PowerValue(scope: "-b", key: "lowpowermode", value: 0)]
    )
    var captureFailure = false
    var suppressFailure = false
    var restoreFailure = false
    var captureCount = 0
    var suppressions: [Snapshot] = []
    var restorations: [Snapshot] = []

    func capture() throws -> Snapshot {
        captureCount += 1
        if captureFailure { throw StubFailure.capture }
        return snapshot
    }

    func suppress(_ snapshot: Snapshot) throws {
        suppressions.append(snapshot)
        if suppressFailure { throw StubFailure.suppress }
    }

    func restore(_ snapshot: Snapshot) throws {
        restorations.append(snapshot)
        if restoreFailure { throw StubFailure.restore }
    }
}

private final class FakeStore: GuardStore {
    var state: PendingState?
    var saveFailure = false
    var saves: [PendingState] = []
    var clearCount = 0

    func load() throws -> PendingState? { state }

    func save(_ state: PendingState) throws {
        if saveFailure { throw StubFailure.save }
        saves.append(state)
        self.state = state
    }

    func clear() throws {
        clearCount += 1
        state = nil
    }
}

private struct Fixture {
    let system: FakeSystem
    let store: FakeStore
    let engine: SleepGuard
    let transitions: SleepTransitions

    init() throws {
        system = FakeSystem()
        store = FakeStore()
        engine = try SleepGuard(system: system, store: store)
        transitions = SleepTransitions(engine: engine)
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func expectFailure(_ expected: StubFailure, _ action: () throws -> Void) throws {
    do {
        try action()
    } catch let actual as StubFailure {
        try expect(actual == expected, "Expected \(expected), received \(actual)")
        return
    }
    throw TestFailure(description: "Expected \(expected) to be thrown")
}

@main
struct SleepTransitionTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("display then lock then system preserves unlock gate", displayThenSystem),
            ("system then lock then display preserves unlock gate", systemThenDisplay),
            ("lock before display sleep remains eligible", lockBeforeDisplay),
            ("locked display wake keeps suppression", lockedDisplayWake),
            ("verified full wake without unlock event stays suppressed", wakeWithoutUnlock),
            ("new sleep after full wake rotates unlock gate", freshSleepAfterFullWake),
            ("any wake starts a fresh gate despite another asleep source", partialWakeStartsFreshGate),
            ("missing display wake cannot admit a stale unlock callback", missingDisplayWakeRejectsStaleUnlock),
            ("failed boundary persistence remains eligible for retry", failedBoundarySaveRetries),
            ("duplicate sleep preserves snapshot and gate", duplicateSleep),
            ("authorized partial restoration retries on verified wake", authorizedWakeRetry),
            ("authorized partial restoration remains suppressed when locked", authorizedLockedWake),
            ("new overlapping sleep invalidates partial restoration authorization", sleepAfterPartialRestore),
            ("suppression failure still records lock", suppressionFailureRecordsLock),
            ("overlap suppression failure preserves lock", overlapFailurePreservesLock),
            ("failed capture is retried by overlapping sleep", captureRetry),
            ("failed initial save is retried by overlapping sleep", saveRetry),
            ("failed lock save never permits restoration", lockSaveFailure),
            ("suppression error survives concurrent lock save failure", suppressionAndLockSaveFailure),
            ("sleep after completed restoration captures a fresh snapshot", sleepAfterCompletedRestore)
        ]
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
        print("\(tests.count) sleep transition tests passed.")
    }

    private static func overlappingOrder(_ first: SleepSource, _ second: SleepSource) throws {
        let f = try Fixture()
        let original = f.system.snapshot
        try f.transitions.sleep(first, sessionLocked: false)
        let id = f.engine.pending?.id
        try f.engine.didLock()
        f.system.snapshot = Snapshot(wifi: ["en0": false], bluetooth: false, power: [])
        try f.transitions.sleep(second, sessionLocked: true)
        try expect(f.engine.pending?.id == id, "Overlapping sleep replaced the unlock gate")
        try expect(f.engine.pending?.sawLock == true, "Overlapping sleep discarded lock evidence")
        try expect(f.engine.pending?.snapshot == original, "Overlapping sleep changed the original snapshot")
        try expect(f.system.captureCount == 1, "Overlapping sleep recaptured suppressed settings")
        try expect(f.store.saves.count == 2, "Overlap wrote an unnecessary new gate")
        try expect(f.system.suppressions == [original, original], "Overlap did not reassert original settings")
        try f.engine.didUnlock(sessionVerified: true)
        try expect(f.system.restorations == [original] && f.engine.pending == nil, "Verified unlock failed after overlapping sleep")
    }

    private static func displayThenSystem() throws {
        try overlappingOrder(.display, .system)
    }

    private static func systemThenDisplay() throws {
        try overlappingOrder(.system, .display)
    }

    private static func lockBeforeDisplay() throws {
        let f = try Fixture()
        try f.engine.didLock()
        try f.transitions.sleep(.display, sessionLocked: true)
        try expect(f.engine.pending?.sawLock == true && f.store.state?.sawLock == true, "Lock preceding capture was lost")
        try f.engine.didUnlock(sessionVerified: true)
        try expect(f.system.restorations.count == 1 && f.engine.pending == nil, "Lock preceding display sleep prevented recovery")
    }

    private static func lockedDisplayWake() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: true)
        let pending = f.engine.pending
        try f.transitions.wake(.display, sessionVerified: false)
        try expect(f.engine.pending == pending && f.store.state == pending, "Locked display wake changed recovery state")
        try expect(f.system.restorations.isEmpty && f.system.suppressions.count == 2, "Locked display wake did not maintain suppression")
    }

    private static func wakeWithoutUnlock() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: true)
        try f.transitions.sleep(.system, sessionLocked: true)
        let id = f.engine.pending?.id
        try f.transitions.wake(.system, sessionVerified: true)
        try f.transitions.wake(.display, sessionVerified: true)
        try expect(f.system.restorations.isEmpty && f.store.clearCount == 0, "Wake inferred unlock authorization from session state")
        try expect(f.engine.pending?.id == id && f.engine.pending?.restorationAuthorized == false, "Full wake authorized restoration")
        try expect(f.system.suppressions.count == 4, "Full wake failed to reassert suppression")
    }

    private static func freshSleepAfterFullWake() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: true)
        try f.transitions.sleep(.system, sessionLocked: true)
        let id = f.engine.pending?.id
        let snapshot = f.engine.pending?.snapshot
        try f.transitions.wake(.display, sessionVerified: false)
        try f.transitions.wake(.system, sessionVerified: false)
        try f.transitions.sleep(.system, sessionLocked: false)
        try expect(f.engine.pending?.id != id, "New sleep after full wake reused the gate")
        try expect(f.engine.pending?.sawLock == false && f.engine.pending?.restorationAuthorized == false, "New sleep retained old unlock eligibility")
        try expect(f.engine.pending?.snapshot == snapshot && f.system.captureCount == 1, "New sleep lost the unrecovered snapshot")
        try f.engine.didUnlock(sessionVerified: true)
        try expect(f.system.restorations.isEmpty, "Prior-cycle lock unlocked a fresh sleep")
    }

    private static func partialWakeStartsFreshGate() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: true)
        try f.transitions.sleep(.system, sessionLocked: true)
        let pending = f.engine.pending
        try f.transitions.wake(.display, sessionVerified: false)
        try f.transitions.sleep(.display, sessionLocked: false)
        try expect(f.engine.pending?.id != pending?.id, "Partial wake allowed a stale gate into the next sleep")
        try expect(f.engine.pending?.snapshot == pending?.snapshot && f.system.captureCount == 1, "Partial wake replaced unrecovered settings")
        try expect(f.engine.pending?.sawLock == false && f.engine.pending?.restorationAuthorized == false, "Partial wake retained prior unlock eligibility")
        let newGate = f.engine.pending
        try f.transitions.sleep(.system, sessionLocked: false)
        try expect(f.engine.pending == newGate, "Fresh boundary was consumed more than once")
    }

    private static func missingDisplayWakeRejectsStaleUnlock() throws {
        let f = try Fixture()
        let original = f.system.snapshot
        try f.transitions.sleep(.display, sessionLocked: true)
        try f.transitions.sleep(.system, sessionLocked: true)
        let delayedUnlockID = f.engine.pending?.id
        try f.transitions.wake(.system, sessionVerified: false)
        // The display remains marked asleep. Re-sleep must nevertheless start
        // a new gate before a queued unlock callback from the old gate fires.
        try f.transitions.sleep(.system, sessionLocked: true)
        let freshUnlockID = f.engine.pending?.id
        try expect(freshUnlockID != delayedUnlockID, "Missing display wake preserved a stale unlock ID")
        try expect(f.engine.pending?.snapshot == original && f.system.captureCount == 1, "New boundary lost the recovery snapshot")
        try expect(f.engine.pending?.sawLock == true && f.store.state?.sawLock == true, "Current locked session was not re-recorded for the new gate")

        // This is the same UUID guard used when delayed verification delivers
        // an unlock event to the real engine.
        if f.engine.pending?.id == delayedUnlockID {
            try f.engine.didUnlock(sessionVerified: true)
        }
        try expect(f.system.restorations.isEmpty && f.engine.pending?.restorationAuthorized == false, "Delayed prior-cycle unlock restored settings")
        if f.engine.pending?.id == freshUnlockID {
            try f.engine.didUnlock(sessionVerified: true)
        }
        try expect(f.system.restorations == [original] && f.engine.pending == nil, "Current-cycle unlock failed after missing display wake")
    }

    private static func failedBoundarySaveRetries() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: true)
        try f.transitions.sleep(.system, sessionLocked: true)
        let previousGate = f.engine.pending
        try f.transitions.wake(.system, sessionVerified: false)
        f.store.saveFailure = true
        try expectFailure(.save) { try f.transitions.sleep(.system, sessionLocked: false) }
        try expect(f.engine.pending == previousGate, "Failed new boundary changed the prior durable gate")
        f.store.saveFailure = false
        try f.transitions.sleep(.system, sessionLocked: false)
        try expect(f.engine.pending?.id != previousGate?.id, "Failed save consumed a wake boundary without creating a fresh gate")
        try expect(f.engine.pending?.sawLock == false, "Retried new boundary retained prior lock eligibility")
    }

    private static func duplicateSleep() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: true)
        let pending = f.engine.pending
        try f.transitions.sleep(.display, sessionLocked: false)
        try expect(f.engine.pending == pending && f.store.saves.count == 2, "Duplicate event reset the gate or lock")
        try expect(f.system.captureCount == 1 && f.system.suppressions.count == 2, "Duplicate event did not reassert captured settings")
    }

    private static func authorizeFailedRestore(_ f: Fixture) throws {
        try f.transitions.sleep(.display, sessionLocked: true)
        f.system.restoreFailure = true
        try expectFailure(.restore) { try f.engine.didUnlock(sessionVerified: true) }
        try expect(f.engine.pending?.restorationAuthorized == true, "Restore failure lost genuine unlock authorization")
    }

    private static func authorizedWakeRetry() throws {
        let f = try Fixture()
        try authorizeFailedRestore(f)
        let suppressionCount = f.system.suppressions.count
        f.system.restoreFailure = false
        try f.transitions.wake(.display, sessionVerified: true)
        try expect(f.engine.pending == nil && f.system.restorations.count == 2, "Verified wake failed to retry authorized restoration")
        try expect(f.system.suppressions.count == suppressionCount, "Authorized wake disabled restored radios again")
    }

    private static func authorizedLockedWake() throws {
        let f = try Fixture()
        try authorizeFailedRestore(f)
        let pending = f.engine.pending
        f.system.restoreFailure = false
        try f.transitions.wake(.display, sessionVerified: false)
        try expect(f.engine.pending == pending && f.system.restorations.count == 1, "Locked wake retried restoration")
        try expect(f.system.suppressions.count == 2, "Locked wake did not suppress authorized state")
    }

    private static func sleepAfterPartialRestore() throws {
        let f = try Fixture()
        try authorizeFailedRestore(f)
        let old = f.engine.pending
        try f.transitions.sleep(.system, sessionLocked: false)
        try expect(f.engine.pending?.id != old?.id, "Sleep during interrupted recovery reused an authorized gate")
        try expect(f.engine.pending?.snapshot == old?.snapshot, "New gate lost original settings")
        try expect(f.engine.pending?.restorationAuthorized == false && f.engine.pending?.sawLock == false, "New gate retained restoration eligibility")
        f.system.restoreFailure = false
        try f.transitions.wake(.system, sessionVerified: true)
        try expect(f.system.restorations.count == 1, "Wake restored using the prior gate's authorization")
    }

    private static func suppressionFailureRecordsLock() throws {
        let f = try Fixture()
        f.system.suppressFailure = true
        try expectFailure(.suppress) { try f.transitions.sleep(.display, sessionLocked: true) }
        try expect(f.engine.pending?.sawLock == true && f.store.state?.sawLock == true, "Suppression failure discarded observed lock")
        let id = f.engine.pending?.id
        f.system.suppressFailure = false
        try f.transitions.sleep(.system, sessionLocked: false)
        try expect(f.engine.pending?.id == id && f.engine.pending?.sawLock == true, "Suppression retry replaced the lock gate")
        try f.engine.didUnlock(sessionVerified: true)
        try expect(f.system.restorations.count == 1, "Failed suppression prevented subsequent verified recovery")
    }

    private static func overlapFailurePreservesLock() throws {
        let f = try Fixture()
        try f.transitions.sleep(.system, sessionLocked: false)
        let id = f.engine.pending?.id
        f.system.suppressFailure = true
        try expectFailure(.suppress) { try f.transitions.sleep(.display, sessionLocked: true) }
        try expect(f.engine.pending?.id == id && f.engine.pending?.sawLock == true, "Overlap failure lost the gate or lock evidence")
    }

    private static func captureRetry() throws {
        let f = try Fixture()
        f.system.captureFailure = true
        try expectFailure(.capture) { try f.transitions.sleep(.display, sessionLocked: true) }
        try expect(f.engine.pending == nil && f.store.saves.isEmpty && f.system.suppressions.isEmpty, "Capture failure changed system state")
        f.system.captureFailure = false
        try f.transitions.sleep(.system, sessionLocked: true)
        try expect(f.engine.pending?.sawLock == true && f.system.captureCount == 2, "Overlap failed to retry missing snapshot")
        try expect(f.system.suppressions.count == 1, "Recovered capture did not suppress settings")
    }

    private static func saveRetry() throws {
        let f = try Fixture()
        f.store.saveFailure = true
        try expectFailure(.save) { try f.transitions.sleep(.system, sessionLocked: true) }
        try expect(f.engine.pending == nil && f.system.suppressions.isEmpty, "Initial save failure changed settings")
        f.store.saveFailure = false
        try f.transitions.sleep(.display, sessionLocked: true)
        try expect(f.engine.pending?.sawLock == true && f.system.suppressions.count == 1, "Overlap failed to retry absent durable state")
    }

    private static func lockSaveFailure() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: false)
        f.store.saveFailure = true
        try expectFailure(.save) { try f.transitions.sleep(.system, sessionLocked: true) }
        try expect(f.engine.pending?.sawLock == false, "Failed lock save enabled recovery")
        try f.engine.didUnlock(sessionVerified: true)
        try expect(f.system.restorations.isEmpty, "Failed lock persistence permitted restoration")
    }

    private static func suppressionAndLockSaveFailure() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: false)
        let pending = f.engine.pending
        f.system.suppressFailure = true
        f.store.saveFailure = true
        try expectFailure(.suppress) { try f.transitions.sleep(.system, sessionLocked: true) }
        try expect(f.engine.pending == pending && f.store.state == pending, "Dual failure changed unlock eligibility")
    }

    private static func sleepAfterCompletedRestore() throws {
        let f = try Fixture()
        try f.transitions.sleep(.display, sessionLocked: true)
        let oldID = f.engine.pending?.id
        try f.engine.didUnlock(sessionVerified: true)
        let newSnapshot = Snapshot(wifi: ["en0": false], bluetooth: true, power: [])
        f.system.snapshot = newSnapshot
        try f.transitions.sleep(.system, sessionLocked: true)
        try expect(f.engine.pending?.snapshot == newSnapshot && f.system.captureCount == 2, "Missing pending record did not start a fresh capture")
        try expect(f.engine.pending?.id != oldID && f.engine.pending?.restorationAuthorized == false, "Fresh snapshot reused completed authorization")
    }
}
