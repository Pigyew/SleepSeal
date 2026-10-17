import Foundation

private enum Failure: Error { case save, restore }
private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(description: message) }
}
private final class RecoverySystem: GuardSystem {
    let original = Snapshot(wifi: ["en0": true], bluetooth: true,
                            power: [PowerValue(scope: "-b", key: "powermode", value: 0)])
    var suppressionCount = 0
    var restores: [Snapshot] = []
    var failRestore = false
    func capture() throws -> Snapshot { original }
    func suppress(_ snapshot: Snapshot) throws { suppressionCount += 1 }
    func restore(_ snapshot: Snapshot) throws {
        restores.append(snapshot)
        if failRestore { throw Failure.restore }
    }
}
private final class RecoveryStore: GuardStore {
    var state: PendingState?
    var failSave = false
    func load() throws -> PendingState? { state }
    func save(_ state: PendingState) throws {
        if failSave { throw Failure.save }
        self.state = state
    }
    func clear() throws { state = nil }
}
private struct Fixture {
    let system: RecoverySystem
    let store: RecoveryStore
    let engine: SleepGuard
    init() throws {
        system = RecoverySystem()
        store = RecoveryStore()
        engine = try SleepGuard(system: system, store: store)
        try engine.beforeSleep()
        try engine.didLock()
    }
}

@main
struct CoreReliabilityTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("slow unlock verification survives repeated polls", delayedVerification),
            ("restart retains gate-specific unlock evidence", restartRetainsCandidate),
            ("unlocked polling cannot invent an unlock", ordinaryPolling),
            ("re-lock invalidates an unverified candidate", relockInvalidatesCandidate),
            ("new sleep rejects a delayed old-gate callback", newSleepRejectsCandidate),
            ("candidate persistence failure grants no authority", candidateSaveFailure),
            ("authorization persistence failure retries safely", authorizationSaveFailure),
            ("partial restoration keeps durable authority and snapshot", partialRestore),
            ("old records decode without unlock evidence", oldRecoveryRecord),
            ("unrelated and unqualified candidate records are ignored", mismatchedCandidate),
            ("explicit recovery failure preserves the original snapshot", manualRecoveryFailure)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) core reliability tests passed without hardware changes.")
    }

    static func delayedVerification() throws {
        let f = try Fixture()
        let gate = f.engine.pending!.id
        try f.engine.observedUnlock(gateID: gate, sessionVerified: false, observedAt: Date(timeIntervalSince1970: 10))
        let candidate = f.engine.pending?.unlockCandidate
        for _ in 0..<24 { try f.engine.reconcile(sessionVerified: false) }
        try expect(f.engine.pending?.unlockCandidate == candidate, "Verification retry expired the genuine unlock")
        try expect(f.system.restores.isEmpty, "Unverified polling restored settings")
        try f.engine.reconcile(sessionVerified: true)
        try expect(f.system.restores == [f.system.original], "Late verification failed to restore the original state")
        try expect(f.engine.pending == nil && f.store.state == nil, "Successful delayed recovery retained a record")
    }

    static func restartRetainsCandidate() throws {
        let f = try Fixture()
        try f.engine.observedUnlock(gateID: f.engine.pending!.id, sessionVerified: false)
        f.store.state = try JSONDecoder().decode(PendingState.self, from: JSONEncoder().encode(f.store.state!))
        let restarted = try SleepGuard(system: f.system, store: f.store)
        try expect(f.system.restores.isEmpty, "Restart restored without a verified session")
        try restarted.reconcile(sessionVerified: true)
        try expect(restarted.pending == nil && f.system.restores == [f.system.original], "Restart lost durable unlock evidence")
    }

    static func ordinaryPolling() throws {
        let f = try Fixture()
        for _ in 0..<12 { try f.engine.reconcile(sessionVerified: true) }
        try expect(f.system.restores.isEmpty && f.engine.pending?.restorationAuthorized == false,
                   "An unlocked console state was treated as an unlock event")
    }

    static func relockInvalidatesCandidate() throws {
        let f = try Fixture()
        try f.engine.observedUnlock(gateID: f.engine.pending!.id, sessionVerified: false)
        try f.engine.didLock()
        try expect(f.engine.pending?.unlockCandidate == nil && f.store.state?.unlockCandidate == nil,
                   "Re-lock retained the prior candidate")
        try f.engine.reconcile(sessionVerified: true)
        try expect(f.system.restores.isEmpty, "Old candidate survived a re-lock")
        try f.engine.observedUnlock(gateID: f.engine.pending!.id, sessionVerified: true)
        try expect(f.system.restores.count == 1, "A new genuine unlock could not restore")
    }

    static func newSleepRejectsCandidate() throws {
        let f = try Fixture()
        let oldGate = f.engine.pending!.id
        try f.engine.observedUnlock(gateID: oldGate, sessionVerified: false)
        try f.engine.beforeSleep()
        try f.engine.didLock()
        try f.engine.observedUnlock(gateID: oldGate, sessionVerified: true)
        try f.engine.reconcile(sessionVerified: true)
        try expect(f.engine.pending?.id != oldGate && f.engine.pending?.unlockCandidate == nil,
                   "A new cycle retained old-gate evidence")
        try expect(f.system.restores.isEmpty, "An old callback restored the new cycle")
        try expect(f.engine.pending?.snapshot == f.system.original, "New cycle replaced the original snapshot")
    }

    static func candidateSaveFailure() throws {
        let f = try Fixture()
        f.store.failSave = true
        do { try f.engine.observedUnlock(gateID: f.engine.pending!.id, sessionVerified: false); throw CheckFailure(description: "Expected candidate save failure") }
        catch Failure.save { }
        f.store.failSave = false
        try f.engine.reconcile(sessionVerified: true)
        try expect(f.engine.pending?.unlockCandidate == nil && f.system.restores.isEmpty,
                   "Failed persistence granted recovery authority")
    }

    static func authorizationSaveFailure() throws {
        let f = try Fixture()
        try f.engine.observedUnlock(gateID: f.engine.pending!.id, sessionVerified: false)
        let candidate = f.engine.pending?.unlockCandidate
        f.store.failSave = true
        do { try f.engine.reconcile(sessionVerified: true); throw CheckFailure(description: "Expected authorization save failure") }
        catch Failure.save { }
        try expect(f.system.restores.isEmpty && f.engine.pending?.unlockCandidate == candidate,
                   "Failed authorization changed hardware or lost the candidate")
        f.store.failSave = false
        try f.engine.reconcile(sessionVerified: true)
        try expect(f.system.restores.count == 1 && f.engine.pending == nil, "Authorization retry failed")
    }

    static func partialRestore() throws {
        let f = try Fixture()
        try f.engine.observedUnlock(gateID: f.engine.pending!.id, sessionVerified: false)
        f.system.failRestore = true
        do { try f.engine.reconcile(sessionVerified: true); throw CheckFailure(description: "Expected partial restore failure") }
        catch Failure.restore { }
        try expect(f.engine.pending?.restorationAuthorized == true && f.engine.pending?.unlockCandidate == nil,
                   "Partial recovery lost its durable authorization")
        let suppressions = f.system.suppressionCount
        f.system.failRestore = false
        try f.engine.reconcile(sessionVerified: true)
        try expect(f.system.suppressionCount == suppressions && f.system.restores == [f.system.original, f.system.original],
                   "Retry suppressed restored settings or changed the saved original")
    }

    static func oldRecoveryRecord() throws {
        let f = try Fixture()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.engine.pending!)) as! [String: Any]
        object.removeValue(forKey: "unlockCandidate")
        object.removeValue(forKey: "restorationAuthorized")
        let restored = try JSONDecoder().decode(PendingState.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(restored.snapshot == f.system.original && restored.sawLock,
                   "Old recovery record lost its original settings")
        try expect(!restored.restorationAuthorized && restored.unlockCandidate == nil,
                   "Old schema granted new restoration authority")
        object.removeValue(forKey: "id")
        let oldest = try JSONDecoder().decode(PendingState.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(oldest.snapshot == f.system.original && oldest.unlockCandidate == nil, "Oldest record was not recoverable")
    }

    static func mismatchedCandidate() throws {
        let f = try Fixture()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.engine.pending!)) as! [String: Any]
        object["unlockCandidate"] = ["gateID": UUID().uuidString, "observedAt": 0]
        let wrongGate = try JSONDecoder().decode(PendingState.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(wrongGate.unlockCandidate == nil, "Mismatched candidate was accepted")
        object["unlockCandidate"] = ["gateID": f.engine.pending!.id.uuidString, "observedAt": 0]
        object["sawLock"] = false
        let noLock = try JSONDecoder().decode(PendingState.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(noLock.unlockCandidate == nil, "Candidate without preceding lock was accepted")
    }

    static func manualRecoveryFailure() throws {
        let f = try Fixture()
        f.system.failRestore = true
        do { try f.engine.recover(sessionVerified: true); throw CheckFailure(description: "Expected restore failure") }
        catch Failure.restore { }
        try expect(f.engine.pending?.snapshot == f.system.original && f.store.state?.snapshot == f.system.original,
                   "Pause/quit recovery failure discarded the saved settings")
        f.system.failRestore = false
        try f.engine.recover(sessionVerified: true)
        try expect(f.engine.pending == nil, "Explicit retry failed to clear completed recovery")
    }
}
