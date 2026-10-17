import Foundation

struct BlockingAppIdentity: Hashable {
    let pid: Int32
    let uid: UInt32
    let bundleID: String
    let launchDate: Date
    let displayName: String
    let activationRegular: Bool
    let executablePath: String
}

enum BlockingAssertionKind: String, Codable {
    case system, display
}

struct BlockingSleepAssertion: Equatable {
    let pid: Int32
    let kind: BlockingAssertionKind
}

/// This option permits only normal quit requests to the current user's ordinary
/// foreground-capable apps. It never permits process signals, service stops,
/// administrator commands, bypassing a save dialog, or automatic relaunch.
enum BlockingAppsPolicy {
    static let excludedBundleIDs: Set<String> = [
        "local.sleepseal.guard", "com.apple.finder", "com.apple.dock",
        "com.apple.loginwindow", "com.apple.systemuiserver", "com.apple.installer",
        "com.apple.systempreferences", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.securityagent", "com.apple.windowmanager", "com.apple.setupassistant",
        "com.apple.uiserver", "com.apple.universalaccessauthwarn", "com.apple.screensaver.engine",
        "com.apple.coreauthui", "com.apple.authorizationhost"
    ]

    static func select(assertions: [BlockingSleepAssertion], applications: [BlockingAppIdentity],
                       currentUID: UInt32, ownPID: Int32) -> [BlockingAppIdentity] {
        let blockingPIDs = Set(assertions.map(\.pid))
        // Conflicting metadata for one PID is ambiguous, so skip it entirely.
        let byPID = Dictionary(grouping: applications, by: \.pid)
        return blockingPIDs.sorted().compactMap { pid in
            guard let candidates = byPID[pid], let first = candidates.first,
                  candidates.allSatisfy({ sameProcess(first, $0) && first.activationRegular == $0.activationRegular }),
                  eligible(first, currentUID: currentUID, ownPID: ownPID) else { return nil }
            return first
        }
    }

    static func sameProcess(_ expected: BlockingAppIdentity, _ current: BlockingAppIdentity) -> Bool {
        expected.pid == current.pid && expected.uid == current.uid
            && expected.bundleID == current.bundleID && expected.launchDate == current.launchDate
            && expected.executablePath == current.executablePath
    }

    static func eligible(_ app: BlockingAppIdentity, currentUID: UInt32, ownPID: Int32) -> Bool {
        guard currentUID >= 500, app.uid == currentUID, app.uid != 0,
              app.pid > 1, app.pid != ownPID, app.activationRegular,
              !app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !excludedBundleIDs.contains(app.bundleID.lowercased()),
              app.launchDate.timeIntervalSince1970.isFinite,
              app.launchDate.timeIntervalSince1970 > 0,
              app.executablePath.hasPrefix("/"), !app.executablePath.contains("\0") else { return false }
        return true
    }
}

struct BlockingAppsBatch {
    let id: UUID
    let deadline: TimeInterval
    let startedAt: TimeInterval
    let applications: [BlockingAppIdentity]
}

enum BlockingAppsResetReason {
    case userActivity, wake, explicitSleep, configurationDisabled, protectionPaused
}

/// One serial-queue instance owns the current idle episode. A request is marked
/// before the adapter sends it, so an app refusing to quit or showing a save
/// dialog is not prompted again every ten seconds. All calls use monotonic time.
final class BlockingAppsCoordinator {
    static let maximumBatchSize = 32
    private struct ProcessKey: Hashable {
        let pid: Int32
        let uid: UInt32
        let bundleID: String
        let launchDate: Date
        let executablePath: String
        init(_ app: BlockingAppIdentity) {
            pid = app.pid; uid = app.uid; bundleID = app.bundleID
            launchDate = app.launchDate; executablePath = app.executablePath
        }
    }
    private var attempted: Set<ProcessKey> = []
    private var activeBatch: UUID?
    private var lastInputAt: TimeInterval?
    private var lastObservationAt: TimeInterval?
    private var currentUID: UInt32 = 0
    private var ownPID: Int32 = 0

    func begin(configuration: AppConfiguration, isConsoleOwner: Bool, inputIdleSeconds: TimeInterval,
               systemSleepMinutes: Int?, displaySleepMinutes: Int?, assertions: [BlockingSleepAssertion],
               applications: [BlockingAppIdentity], currentUID: UInt32, ownPID: Int32,
               at time: TimeInterval, budget: TimeInterval = 2, origin: SleepOrigin = .idle,
               requiresIdleThreshold: Bool = true, protectionSelected: Bool? = nil) -> BlockingAppsBatch? {
        guard configuration.protectionEnabled, configuration.quitBlockingApps else {
            reset(reason: configuration.protectionPaused ? .protectionPaused : .configurationDisabled)
            return nil
        }
        guard protectionSelected ?? configuration.triggerPolicy.decision(for: origin).shouldProtect else { return nil }
        guard isConsoleOwner, currentUID >= 500, time.isFinite, time >= 0,
              inputIdleSeconds.isFinite, inputIdleSeconds >= 0,
              budget.isFinite, budget > 0, budget <= 10 else { return nil }
        observeInput(idle: inputIdleSeconds, at: time)
        let eligibleAssertions = assertions.filter { assertion in
            if !requiresIdleThreshold { return true }
            let minutes = assertion.kind == .system ? systemSleepMinutes : displaySleepMinutes
            guard let timer = minutes, timer > 0 else { return false }
            return inputIdleSeconds >= Double(timer) * 60
        }
        let candidates = BlockingAppsPolicy.select(assertions: eligibleAssertions, applications: applications,
            currentUID: currentUID, ownPID: ownPID).filter { !attempted.contains(ProcessKey($0)) }
        guard !candidates.isEmpty else { return nil }
        self.currentUID = currentUID; self.ownPID = ownPID
        let id = UUID()
        activeBatch = id
        // Bound one event's UI work even if a malicious assertion source returns
        // thousands of duplicate or unrelated entries.
        return BlockingAppsBatch(id: id, deadline: time + budget, startedAt: time,
                                 applications: Array(candidates.prefix(Self.maximumBatchSize)))
    }

    /// Call immediately before the normal quit request with a fresh identity
    /// captured by the native adapter. A PID alone is never sufficient.
    func claim(_ app: BlockingAppIdentity, in batch: BlockingAppsBatch,
               current: BlockingAppIdentity, at time: TimeInterval) -> Bool {
        guard activeBatch == batch.id, time.isFinite, time >= batch.startedAt, time < batch.deadline,
              batch.applications.contains(where: { BlockingAppsPolicy.sameProcess($0, app) }),
              BlockingAppsPolicy.sameProcess(app, current),
              BlockingAppsPolicy.eligible(current, currentUID: currentUID, ownPID: ownPID),
              !attempted.contains(ProcessKey(app)) else { return false }
        attempted.insert(ProcessKey(app))
        return true
    }

    func cancelActiveBatch() { activeBatch = nil }

    func reset(reason: BlockingAppsResetReason) {
        activeBatch = nil
        attempted.removeAll()
        lastInputAt = nil
        lastObservationAt = nil
    }

    private func observeInput(idle: TimeInterval, at time: TimeInterval) {
        let inputAt = time - idle
        if let previousTime = lastObservationAt, time < previousTime {
            reset(reason: .userActivity)
        } else if let previousInput = lastInputAt, inputAt > previousInput + 0.5 {
            reset(reason: .userActivity)
        }
        lastInputAt = max(lastInputAt ?? inputAt, inputAt)
        lastObservationAt = time
    }
}
