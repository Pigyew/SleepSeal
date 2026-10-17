import Foundation

struct PowerValue: Codable, Equatable {
    let scope: String
    let key: String
    let value: Int
}

struct Snapshot: Codable, Equatable {
    let wifi: [String: Bool]
    let bluetooth: Bool?
    let power: [PowerValue]
}

struct PendingState: Codable, Equatable {
    let snapshot: Snapshot
    var sawLock: Bool
    let id: UUID
    var restorationAuthorized: Bool

    init(snapshot: Snapshot, sawLock: Bool, id: UUID = UUID(), restorationAuthorized: Bool = false) {
        self.snapshot = snapshot
        self.sawLock = sawLock
        self.id = id
        self.restorationAuthorized = restorationAuthorized
    }
}

protocol GuardSystem {
    func capture() throws -> Snapshot
    func suppress(_ snapshot: Snapshot) throws
    func restore(_ snapshot: Snapshot) throws
}

protocol GuardStore {
    func load() throws -> PendingState?
    func save(_ state: PendingState) throws
    func clear() throws
}

enum SleepGuardError: Error, LocalizedError {
    case sessionNotVerified

    var errorDescription: String? {
        switch self {
        case .sessionNotVerified:
            return "Recovery requires a verified, unlocked console session."
        }
    }
}

/// Call every method on the same serial queue. The saved snapshot is the source
/// of truth until every restoration step, including clearing the store, succeeds.
final class SleepGuard {
    private let system: GuardSystem
    private let store: GuardStore
    private(set) var pending: PendingState?

    init(system: GuardSystem, store: GuardStore) throws {
        self.system = system
        self.store = store
        self.pending = try store.load()
    }

    func beforeSleep() throws {
        let snapshot: Snapshot
        if let state = pending {
            snapshot = state.snapshot
        } else {
            snapshot = try system.capture()
        }

        // Every new sleep starts a fresh unlock gate, even when recovery from a
        // previous sleep is pending. Delayed unlocks must match this new ID.
        let state = PendingState(snapshot: snapshot, sawLock: false)
        // A durable recovery record must exist before the first system change.
        try store.save(state)
        pending = state
        try system.suppress(snapshot)
    }

    func didWake() throws {
        try reassert()
    }

    func didLock() throws {
        guard var state = pending, !state.sawLock else { return }
        state.sawLock = true
        // A failed save must not make an in-memory unlock newly eligible.
        try store.save(state)
        pending = state
    }

    func didUnlock(sessionVerified: Bool) throws {
        guard sessionVerified, pending?.sawLock == true else { return }
        try authorizeAndRestore()
    }

    /// Manual recovery can also restore an interrupted sleep transition that
    /// never produced a lock event, but still requires a verified console user.
    func recover(sessionVerified: Bool) throws {
        guard sessionVerified else { throw SleepGuardError.sessionNotVerified }
        try authorizeAndRestore()
    }

    /// Retry an authorized, possibly partial restoration while the console is
    /// verified as unlocked. A locked or unverified session stays suppressed.
    func reconcile(sessionVerified: Bool) throws {
        if pending?.restorationAuthorized == true && sessionVerified {
            try restorePending()
        } else {
            try reassert()
        }
    }

    func reassert() throws {
        guard let state = pending else { return }
        try system.suppress(state.snapshot)
    }

    private func authorizeAndRestore() throws {
        guard var state = pending else { return }
        if !state.restorationAuthorized {
            state.restorationAuthorized = true
            // Remember authorization before any restore step so a later timer
            // retries a partial restoration instead of disabling radios again.
            try store.save(state)
            pending = state
        }
        try restorePending()
    }

    private func restorePending() throws {
        guard let state = pending else { return }
        try system.restore(state.snapshot)
        try store.clear()
        pending = nil
    }
}
