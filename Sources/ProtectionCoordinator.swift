import Foundation

struct ProtectionCycleDecision: Equatable {
    let origin: SleepOrigin
    let policyDecision: TriggerDecision
    let requested: Bool
    let permissionsMissing: Bool
    let shouldAttemptProtection: Bool
}

/// The event adapter calls this on the guard's serial queue. Configuration
/// changes apply on the next wake boundary. Pending recovery remains in force
/// even if a source is later deselected or an application control is in flight.
final class ProtectionCoordinator {
    private var cyclePolicy: TriggerPolicy?
    private var cycleOrigin: SleepOrigin?
    private var cycleProtected = false
    private(set) var isQuiescing = false

    func decide(origin: SleepOrigin, policy: TriggerPolicy, enabled: Bool,
                ready: Bool, pending: Bool) -> ProtectionCycleDecision {
        if cyclePolicy == nil { cyclePolicy = policy }
        // An actual system event may explain an earlier, skipped display event.
        // Once protection starts, later events cannot rewrite its provenance.
        if cycleOrigin == nil || (!cycleProtected && origin != .unknown) { cycleOrigin = origin }
        let selectedOrigin = cycleOrigin ?? origin
        let decision = (cyclePolicy ?? policy).decision(for: selectedOrigin)
        let requested = !isQuiescing && enabled && decision.shouldProtect
        let shouldAttempt = (requested && ready) || pending
        if shouldAttempt { cycleProtected = true }
        return ProtectionCycleDecision(origin: selectedOrigin, policyDecision: decision,
            requested: requested, permissionsMissing: requested && !ready && !pending,
            shouldAttemptProtection: shouldAttempt)
    }

    func didWake() {
        cyclePolicy = nil
        cycleOrigin = nil
        cycleProtected = false
    }

    /// Pause, quit and uninstall freeze new protection before restoration.
    /// A failed restoration leaves the app operational for a safe retry.
    func recover(freeze: Bool, operation: () throws -> Void) rethrows {
        if freeze { isQuiescing = true }
        do { try operation() }
        catch { isQuiescing = false; throw error }
    }

    func resumeAfterFailedControl() { isQuiescing = false }

    func configurationDidChange(paused: Bool) {
        if !paused { isQuiescing = false }
    }
}
