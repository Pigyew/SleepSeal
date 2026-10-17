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

/// An observed unlock is evidence, not permission to restore. The console
/// session must independently become verified before this candidate is used.
struct UnlockCandidate: Codable, Equatable {
    let gateID: UUID
    let observedAt: Date
}

struct PendingState: Codable, Equatable {
    let snapshot: Snapshot
    var sawLock: Bool
    let id: UUID
    var restorationAuthorized: Bool
    var unlockCandidate: UnlockCandidate?

    init(snapshot: Snapshot, sawLock: Bool, id: UUID = UUID(), restorationAuthorized: Bool = false,
         unlockCandidate: UnlockCandidate? = nil) {
        self.snapshot = snapshot
        self.sawLock = sawLock
        self.id = id
        self.restorationAuthorized = restorationAuthorized
        self.unlockCandidate = unlockCandidate?.gateID == id ? unlockCandidate : nil
    }

    private enum CodingKeys: String, CodingKey {
        case snapshot, sawLock, id, restorationAuthorized, unlockCandidate
    }

    /// Old recovery records remain usable. Missing authorization fields must
    /// default to the restrictive state; an unrelated candidate is discarded.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try values.decode(Snapshot.self, forKey: .snapshot)
        sawLock = try values.decodeIfPresent(Bool.self, forKey: .sawLock) ?? false
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        restorationAuthorized = try values.decodeIfPresent(Bool.self, forKey: .restorationAuthorized) ?? false
        let candidate = try values.decodeIfPresent(UnlockCandidate.self, forKey: .unlockCandidate)
        unlockCandidate = candidate?.gateID == id && sawLock ? candidate : nil
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

        // A new sleep invalidates both an old unlock event and authorization,
        // while preserving the original settings if recovery remains pending.
        let state = PendingState(snapshot: snapshot, sawLock: false)
        try store.save(state)
        pending = state
        try system.suppress(snapshot)
    }

    func didWake() throws {
        try reassert()
    }

    func didLock() throws {
        guard var state = pending else { return }
        guard !state.sawLock || state.unlockCandidate != nil else { return }
        state.sawLock = true
        // A re-lock cancels an unlock that has not yet passed verification.
        // Already-authorized partial restoration remains retryable, as before.
        state.unlockCandidate = nil
        try store.save(state)
        pending = state
    }

    /// Record this once for a real unlock notification. The gate ID is captured
    /// when the notification arrives, so queued work cannot unlock a new cycle.
    /// A slow console update is retried by reconcile instead of a short timer.
    func observedUnlock(gateID: UUID, sessionVerified: Bool, observedAt: Date = Date()) throws {
        guard var state = pending, state.id == gateID, state.sawLock else { return }
        if sessionVerified {
            try authorizeAndRestore()
        } else if state.unlockCandidate == nil {
            state.unlockCandidate = UnlockCandidate(gateID: gateID, observedAt: observedAt)
            try store.save(state)
            pending = state
        }
    }

    /// Compatibility entry point for callers already handling an unlock event.
    func didUnlock(sessionVerified: Bool) throws {
        guard let id = pending?.id else { return }
        try observedUnlock(gateID: id, sessionVerified: sessionVerified)
    }

    /// Manual recovery can restore an interrupted transition without a lock
    /// event, but still requires the current, verified console user.
    func recover(sessionVerified: Bool) throws {
        guard sessionVerified else { throw SleepGuardError.sessionNotVerified }
        try authorizeAndRestore()
    }

    /// Polling alone never authorizes recovery. A durable, gate-matched unlock
    /// candidate (or previously authorized partial recovery) must also exist.
    func reconcile(sessionVerified: Bool) throws {
        guard let state = pending else { return }
        if sessionVerified && state.restorationAuthorized {
            try restorePending()
        } else if sessionVerified && state.sawLock && state.unlockCandidate?.gateID == state.id {
            try authorizeAndRestore()
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
        if !state.restorationAuthorized || state.unlockCandidate != nil {
            state.restorationAuthorized = true
            state.unlockCandidate = nil
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
