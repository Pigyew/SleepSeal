import Foundation

enum SleepSource {
    case display
    case system
}

/// Call every method on the same serial queue as SleepGuard. Display sleep and
/// system sleep can describe one transition, with a lock event between them.
final class SleepTransitions {
    private let engine: SleepGuard
    private var displayAsleep = false
    private var systemAsleep = false
    private var requiresFreshGate = false

    init(engine: SleepGuard) {
        self.engine = engine
    }

    func sleep(_ source: SleepSource, sessionLocked: Bool) throws {
        let alreadySleeping = displayAsleep || systemAsleep
        let previousGateID = engine.pending?.id
        let startsFreshGate = requiresFreshGate || !alreadySleeping || engine.pending == nil
            || engine.pending?.restorationAuthorized == true
        setAsleep(source, true)

        var transitionError: Error?
        do {
            if startsFreshGate {
                requiresFreshGate = true
                try engine.beforeSleep()
            } else {
                // Preserve the snapshot and recorded lock when the other sleep
                // notification arrives for the same sleep cycle.
                try engine.reassert()
            }
        } catch {
            transitionError = error
        }
        // Consume a wake boundary only once a new gate exists. If capture or
        // persistence failed, the next notification must retry that boundary.
        // A suppression failure after persistence still created a valid gate.
        if startsFreshGate && engine.pending?.id != previousGateID {
            requiresFreshGate = false
        }

        // Suppression can partially fail after the recovery record was saved.
        // Keep valid lock evidence even when that system operation throws.
        if sessionLocked {
            do {
                try engine.didLock()
            } catch {
                if transitionError == nil { transitionError = error }
            }
        }
        if let error = transitionError { throw error }
    }

    func wake(_ source: SleepSource, sessionVerified: Bool) throws {
        setAsleep(source, false)
        // The other source's wake may arrive late or never arrive. Any wake
        // separates sleep cycles so stale unlock callbacks cannot cross them.
        requiresFreshGate = true
        // An unlocked session alone is not an unlock event. Only retry a
        // restoration that a previous genuine unlock already authorized.
        if engine.pending?.restorationAuthorized == true {
            try engine.reconcile(sessionVerified: sessionVerified)
        } else {
            try engine.didWake()
        }
    }

    private func setAsleep(_ source: SleepSource, _ asleep: Bool) {
        switch source {
        case .display: displayAsleep = asleep
        case .system: systemAsleep = asleep
        }
    }
}
