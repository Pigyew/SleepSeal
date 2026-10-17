import Foundation
import IOKit.pwr_mgt

private enum FakeProbeError: Error { case unavailable }

private final class FakeBlockingHost: BlockingAppsHost {
    var currentUID: UInt32 = 501
    var ownPID: Int32 = 9999
    var time: TimeInterval = 100
    var console = true
    var assertions: [BlockingSleepAssertion] = []
    var applications: [Int32: BlockingAppIdentity] = [:]
    var unknownPresence = Set<Int32>()
    var requested: [BlockingAppIdentity] = []
    var assertionReads = 0
    var failAssertionRead = Set<Int>()
    var beforeAssertionRead: (() throws -> Void)?
    var beforeApplicationRead: (() -> Void)?
    var beforeMain: (() -> Void)?
    var beforeQuit: (() -> Void)?
    var whileWaiting: (() -> Void)?
    var acceptQuit = true
    var refusedPIDs = Set<Int32>()
    var exitAfterRequest = true
    var delayedMain = false
    var queued: [() -> Void] = []
    var mainDispatches = 0
    var mainDeadlines: [TimeInterval] = []
    func now() -> TimeInterval { time }
    func isConsoleOwner() -> Bool { console }
    func activeAssertions() throws -> [BlockingSleepAssertion] {
        assertionReads += 1
        try beforeAssertionRead?()
        if failAssertionRead.contains(assertionReads) { throw FakeProbeError.unavailable }
        return assertions
    }
    func application(pid: Int32) -> BlockingAppIdentity? {
        beforeApplicationRead?()
        return applications[pid]
    }
    func presence(of identity: BlockingAppIdentity) -> BlockingProcessPresence {
        if unknownPresence.contains(identity.pid) { return .unknown }
        guard let current = applications[identity.pid] else { return .gone }
        return BlockingAppsPolicy.sameProcess(identity, current) ? .original : .gone
    }
    func normalQuit(_ identity: BlockingAppIdentity, permitted: () -> Bool) -> Bool {
        beforeQuit?()
        guard permitted(), console, let current = applications[identity.pid],
              BlockingAppsPolicy.sameProcess(identity, current) else { return false }
        if acceptQuit && !refusedPIDs.contains(identity.pid) {
            requested.append(identity)
            if exitAfterRequest { applications.removeValue(forKey: identity.pid) }
        }
        return acceptQuit && !refusedPIDs.contains(identity.pid)
    }
    func onMain(deadline: TimeInterval, cancelled: @escaping () -> Bool,
                action: @escaping (@escaping () -> Bool) -> BlockingQuitAttempt) -> BlockingQuitAttempt {
        mainDispatches += 1
        mainDeadlines.append(deadline)
        let gate = BlockingMainQuitGate()
        let permitted = { gate.permitted && self.time < deadline && !cancelled() }
        if delayedMain {
            queued.append { _ = action(permitted) }
            time = deadline
            gate.close()
            return .timedOut
        }
        beforeMain?()
        defer { gate.close() }
        return action(permitted)
    }
    func waitBriefly(until deadline: TimeInterval) {
        time = min(deadline, time + 0.1)
        whileWaiting?()
    }
}

@main
private struct BlockingAppsAdapterTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        func app(_ pid: Int32 = 201, uid: UInt32 = 501, start: TimeInterval = 10,
                 bundle: String = "org.example.Writer", regular: Bool = true,
                 executable: String = "/Applications/Writer.app/Contents/MacOS/Writer") -> BlockingAppIdentity {
            BlockingAppIdentity(pid: pid, uid: uid, bundleID: bundle,
                launchDate: Date(timeIntervalSince1970: start), displayName: "Writer",
                activationRegular: regular, executablePath: executable)
        }
        func host(_ suppliedApps: [BlockingAppIdentity]? = nil) -> FakeBlockingHost {
            let apps = suppliedApps ?? [app()]
            let host = FakeBlockingHost()
            host.applications = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })
            host.assertions = apps.map { BlockingSleepAssertion(pid: $0.pid, kind: .system) }
            return host
        }
        func run(_ host: FakeBlockingHost, applications: [BlockingAppIdentity]? = nil,
                 cancelled: @escaping () -> Bool = { false },
                 shouldRequest: ((BlockingAppIdentity) -> Bool)? = nil) -> BlockingAppsResult {
            BlockingApps.requestQuitBlockingApps(host: host, applications: applications,
                deadline: 102, cancelled: cancelled, shouldRequest: shouldRequest)
        }

        let typed: NSDictionary = [
            NSNumber(value: 201): [
                ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255],
                ["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": 255],
                ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 0],
                ["AssertType": "PreventUserIdleDisplaySleep"],
                ["AssertType": "NetworkClientActive", "AssertLevel": 255],
                ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": "255"]
            ],
            "pid 202": [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]],
            NSNumber(value: -1): [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]],
            NSNumber(value: Int64(Int32.max) + 1): [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]]
        ]
        let read = BlockingAssertionReader.parse(typed)
        check(read.count == 2 && read.allSatisfy { $0.pid == 201 }, "Use only numeric PID keys and active typed sleep assertions")
        check(Set(read.map(\.kind)) == [.system, .display], "Distinguish display and system assertion types")
        let off = BlockingAssertionReader.parse([NSNumber(value: 201): [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 1]]])
        check(off.isEmpty, "Only the documented active level 255 qualifies")
        for invalidPID in [NSNumber(value: 201.5), NSNumber(value: true), NSNumber(value: Double.infinity), NSNumber(value: Double.nan)] {
            let invalid = BlockingAssertionReader.parse([invalidPID: [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": 255]]])
            check(invalid.isEmpty, "Fractional, boolean and nonfinite PID numbers cannot select an application")
        }
        for invalidLevel in [NSNumber(value: 255.5), NSNumber(value: true), NSNumber(value: Double.infinity), NSNumber(value: Double.nan)] {
            let invalid = BlockingAssertionReader.parse([NSNumber(value: 201): [["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": invalidLevel]]])
            check(invalid.isEmpty, "Fractional, boolean and nonfinite assertion levels are inactive")
        }
        let legacy = BlockingAssertionReader.parse([NSNumber(value: 201): [["AssertType": "NoIdleSleepAssertion", "AssertLevel": 255], ["AssertType": "NoDisplaySleepAssertion", "AssertLevel": 255]]])
        check(legacy.count == 2, "Recognize documented legacy assertion aliases")

        let inventoryHost = host([app(), app(202, uid: 502), app(203, uid: 0), app(204, bundle: "com.apple.finder"), app(205, regular: false)])
        let inventory = try BlockingApps.inventory(host: inventoryHost)
        check(inventory.applications == [app()], "Inventory exposes only eligible current-user apps")
        check(inventoryHost.requested.isEmpty, "Inventory is read-only")

        let closedHost = host()
        let closed = run(closedHost)
        check(closed.requestedCount == 1 && closed.terminatedCount == 1 && closed.remainingCount == 0,
              "Report exit only after the original process has actually gone")
        check(closedHost.requested == [app()] && closedHost.mainDispatches == 1, "One normal quit request per selected app")

        let saveHost = host(); saveHost.exitAfterRequest = false
        let save = run(saveHost)
        check(save.requestedCount == 1 && save.terminatedCount == 0 && save.remainingCount == 1,
              "A save prompt or unresponsive app is still running after a successful quit request")
        check(save.timedOut && saveHost.requested.count == 1, "Deadline stops waiting without a second request or force quit")

        let refusedHost = host(); refusedHost.acceptQuit = false
        let refused = run(refusedHost)
        check(refused.requestedCount == 0 && refused.terminatedCount == 0 && refused.remainingCount == 1,
              "A refused request is not reported as sent or closed")

        let staleHost = host()
        staleHost.beforeMain = { staleHost.applications[201] = app(start: 11) }
        let stale = run(staleHost)
        check(staleHost.requested.isEmpty && stale.terminatedCount == 0, "Main-thread identity check rejects PID reuse")

        let executableHost = host()
        executableHost.beforeMain = { executableHost.applications[201] = app(executable: "/Applications/Other.app/Contents/MacOS/Other") }
        _ = run(executableHost)
        check(executableHost.requested.isEmpty, "Executable path is part of the identity check")

        let releasedHost = host()
        releasedHost.beforeMain = { releasedHost.assertions = [] }
        let released = run(releasedHost)
        check(releasedHost.requested.isEmpty && released.terminatedCount == 0, "An app that released its assertion is not quit")

        let switchedHost = host()
        switchedHost.beforeMain = { switchedHost.console = false }
        _ = run(switchedHost)
        check(switchedHost.requested.isEmpty, "Console ownership is rechecked on main before any quit")

        let noConsoleHost = host(); noConsoleHost.console = false
        let noConsole = run(noConsoleHost)
        check(noConsole.error != nil && noConsoleHost.mainDispatches == 0, "Inactive accounts cannot begin quit preparation")

        var cancelled = true
        let cancelledHost = host()
        let cancelledBefore = run(cancelledHost, cancelled: { cancelled })
        check(cancelledBefore.cancelled && cancelledHost.assertionReads == 0 && cancelledHost.requested.isEmpty,
              "A cancelled batch performs no inventory or quit work")
        cancelled = false
        cancelledHost.beforeMain = { cancelled = true }
        let cancelledMain = run(cancelledHost, cancelled: { cancelled })
        check(cancelledMain.cancelled && cancelledHost.requested.isEmpty, "Queued main work observes cancellation before acting")

        cancelled = false
        let lateHost = host(); lateHost.delayedMain = true
        let late = run(lateHost, cancelled: { cancelled })
        lateHost.time = 103
        lateHost.queued.forEach { $0() }
        check(late.timedOut && lateHost.requested.isEmpty, "Main work queued past the deadline cannot send a late quit")

        let finalGuardHost = host()
        finalGuardHost.beforeQuit = { finalGuardHost.time = 103 }
        _ = run(finalGuardHost)
        check(finalGuardHost.requested.isEmpty, "Final permission check prevents a request after revalidation exhausted the budget")

        let failedProbeHost = host(); failedProbeHost.failAssertionRead = [3]
        let failedProbe = run(failedProbeHost)
        check(failedProbe.error != nil && failedProbeHost.requested.isEmpty,
              "Failure to read fresh main-thread assertions fails closed")

        let deniedHost = host()
        let denied = run(deniedHost, shouldRequest: { _ in false })
        check(denied.candidateCount == 1 && deniedHost.mainDispatches == 0 && deniedHost.requested.isEmpty,
              "Coordinator attempt ledger can reject a repeated save prompt before dispatch")

        let whitelistHost = host([app(), app(202)])
        let whitelisted = run(whitelistHost, applications: [app()])
        check(whitelisted.candidateCount == 1 && whitelistHost.requested == [app()], "Only immutable batch identities may be targeted")

        let oldWhitelistHost = host()
        let oldWhitelist = run(oldWhitelistHost, applications: [app(start: 9)])
        check(oldWhitelist.candidateCount == 0 && oldWhitelistHost.requested.isEmpty, "A stale batch PID cannot select a new process")

        let unknownHost = host(); unknownHost.unknownPresence = [201]; unknownHost.exitAfterRequest = false
        let unknown = run(unknownHost)
        check(unknown.terminatedCount == 0 && unknown.remainingCount == 1, "Inspection failure never counts as a closed application")

        cancelled = false
        let observingHost = host(); observingHost.exitAfterRequest = false
        observingHost.whileWaiting = { cancelled = true }
        let observing = run(observingHost, cancelled: { cancelled })
        check(observing.cancelled && observing.terminatedCount == 0 && observing.remainingCount == 1,
              "Cancellation during observation preserves the still-open result")

        let expiredHost = host(); expiredHost.time = 103
        let expired = run(expiredHost)
        check(expired.timedOut && expiredHost.assertionReads == 0 && expiredHost.requested.isEmpty,
              "Expired work is rejected before gathering app data")

        // Compose the real pure coordinator and native-driver algorithm with a
        // fake host. A refused normal quit must not prompt again when the same
        // idle episode later receives an actual sleep event.
        let ledgerHost = host(); ledgerHost.acceptQuit = false; ledgerHost.time = 120
        let coordinator = BlockingAppsCoordinator()
        var configuration = AppConfiguration(existingInstallation: true)
        configuration.quitBlockingApps = true
        guard let idleBatch = coordinator.begin(configuration: configuration, isConsoleOwner: true,
            inputIdleSeconds: 120, systemSleepMinutes: 1, displaySleepMinutes: 1,
            assertions: ledgerHost.assertions, applications: Array(ledgerHost.applications.values),
            currentUID: 501, ownPID: 9999, at: 120, budget: 2) else {
            preconditionFailure("Expected an eligible idle batch")
        }
        let idleResult = BlockingApps.requestQuitBlockingApps(host: ledgerHost, applications: idleBatch.applications,
            deadline: idleBatch.deadline, cancelled: { false }, shouldRequest: { current in
                coordinator.claim(current, in: idleBatch, current: current, at: ledgerHost.time)
            })
        coordinator.cancelActiveBatch()
        check(idleResult.requestedCount == 0 && idleResult.remainingCount == 1 && ledgerHost.mainDispatches == 1,
              "Refusal is observed while the attempt ledger still records the ordinary request")
        ledgerHost.time = 121
        let actualBatch = coordinator.begin(configuration: configuration, isConsoleOwner: true,
            inputIdleSeconds: 121, systemSleepMinutes: 1, displaySleepMinutes: 1,
            assertions: ledgerHost.assertions, applications: Array(ledgerHost.applications.values),
            currentUID: 501, ownPID: 9999, at: 121, budget: 2, origin: .idle,
            requiresIdleThreshold: false, protectionSelected: true)
        check(actualBatch == nil && ledgerHost.mainDispatches == 1,
              "Idle-to-actual-sleep overlap cannot resend a refused normal quit in the same episode")
        coordinator.reset(reason: .userActivity)
        let freshBatch = coordinator.begin(configuration: configuration, isConsoleOwner: true,
            inputIdleSeconds: 0, systemSleepMinutes: 1, displaySleepMinutes: 1,
            assertions: ledgerHost.assertions, applications: Array(ledgerHost.applications.values),
            currentUID: 501, ownPID: 9999, at: 122, budget: 2, origin: .manual,
            requiresIdleThreshold: false, protectionSelected: true)
        check(freshBatch != nil, "A new explicit user episode may make a new ordinary quit attempt")

        let cancellation = BlockingAppsCancellation()
        let token = cancellation.token()
        let tokenHost = host()
        tokenHost.beforeMain = { cancellation.cancel() }
        let tokenResult = run(tokenHost, cancelled: { cancellation.isCancelled(token) })
        check(tokenResult.cancelled && tokenHost.requested.isEmpty,
              "A real thread-safe cancellation epoch cancels the injected main-thread request")

        let manyApps = (201...233).map { app(Int32($0)) }
        let manyHost = host(manyApps)
        let many = BlockingApps.prepareForManualSleep(host: manyHost, deadline: 108, cancelled: { false })
        check(many.canProceedWithSleep && many.candidateCount == 33 && many.requestedCount == 33
              && many.terminatedCount == 33 && many.remainingCount == 0,
              "Manual preparation accounts for all 33 blockers across bounded batches")
        check(Set(manyHost.requested.map(\.pid)).count == 33 && manyHost.mainDeadlines.allSatisfy { $0 == 108 },
              "Every blocker receives at most one request under the original shared deadline")

        let lastRefusedHost = host(manyApps); lastRefusedHost.refusedPIDs = [233]
        let lastRefused = BlockingApps.prepareForManualSleep(host: lastRefusedHost, deadline: 108, cancelled: { false })
        check(!lastRefused.canProceedWithSleep && lastRefused.requestedCount == 32
              && lastRefused.remainingApps.map(\.pid) == [233] && lastRefusedHost.mainDispatches == 33,
              "A refused 33rd blocker prevents manual sleep after the first batch exits")

        let budgetHost = host((201...240).map { app(Int32($0)) })
        budgetHost.beforeQuit = { budgetHost.time += 0.21 }
        let budget = BlockingApps.prepareForManualSleep(host: budgetHost, deadline: 108, cancelled: { false })
        check(!budget.canProceedWithSleep && budget.timedOut && budget.requestedCount >= 32
              && budget.requestedCount < 40 && budget.remainingCount > 0,
              "A later batch cannot restart the eight-second total preparation budget")
        check(budgetHost.mainDeadlines.allSatisfy { $0 == 108 }, "All batches retain the same absolute deadline")

        var manualCancelled = false
        let cancelledManyHost = host(manyApps)
        cancelledManyHost.beforeMain = { if cancelledManyHost.requested.count == 32 { manualCancelled = true } }
        let cancelledMany = BlockingApps.prepareForManualSleep(host: cancelledManyHost, deadline: 108,
            cancelled: { manualCancelled })
        check(!cancelledMany.canProceedWithSleep && cancelledMany.cancelled && cancelledMany.requestedCount == 32
              && cancelledMany.remainingApps.map(\.pid) == [233],
              "Cancellation between batches prevents the remaining request and manual sleep")

        let cancelledScanHost = host([])
        manualCancelled = false
        cancelledScanHost.beforeAssertionRead = { manualCancelled = true }
        let cancelledScan = BlockingApps.prepareForManualSleep(host: cancelledScanHost, deadline: 108,
            cancelled: { manualCancelled })
        check(cancelledScan.cancelled && !cancelledScan.canProceedWithSleep && cancelledScanHost.requested.isEmpty,
              "Cancellation during an empty final inventory cannot authorize sleep")

        let partialScanHost = host(manyApps)
        partialScanHost.beforeApplicationRead = { partialScanHost.time += 0.4 }
        let partialScan = BlockingApps.prepareForManualSleep(host: partialScanHost, deadline: 108, cancelled: { false })
        check(partialScan.timedOut && !partialScan.canProceedWithSleep && partialScanHost.requested.isEmpty,
              "An inventory cut short by the deadline is not a complete successful scan")
        let expiredEmptyHost = host([])
        expiredEmptyHost.beforeAssertionRead = { expiredEmptyHost.time = 108 }
        let expiredEmpty = BlockingApps.prepareForManualSleep(host: expiredEmptyHost, deadline: 108, cancelled: { false })
        check(expiredEmpty.timedOut && !expiredEmpty.canProceedWithSleep,
              "An empty inventory that finishes at the deadline still fails closed")

        let newBlockerHost = host(Array(manyApps.prefix(32)))
        var addedBlocker = false
        newBlockerHost.beforeAssertionRead = {
            if newBlockerHost.requested.count == 32 && !addedBlocker {
                addedBlocker = true
                let newcomer = app(999)
                newBlockerHost.applications[999] = newcomer
                newBlockerHost.assertions.append(BlockingSleepAssertion(pid: 999, kind: .display))
            }
        }
        newBlockerHost.refusedPIDs = [999]
        let newBlocker = BlockingApps.prepareForManualSleep(host: newBlockerHost, deadline: 108, cancelled: { false })
        check(!newBlocker.canProceedWithSleep && newBlocker.candidateCount == 33
              && newBlocker.remainingApps.map(\.pid) == [999] && newBlockerHost.mainDispatches == 33,
              "Final full inventory catches a newly blocking app outside the initial candidate list")

        let failedFinalHost = host()
        failedFinalHost.beforeAssertionRead = {
            if !failedFinalHost.requested.isEmpty { throw FakeProbeError.unavailable }
        }
        let failedFinal = BlockingApps.prepareForManualSleep(host: failedFinalHost, deadline: 108, cancelled: { false })
        check(failedFinal.error != nil && !failedFinal.canProceedWithSleep && failedFinal.terminatedCount == 1,
              "Failure of the final full inventory cannot be hidden by a successful batch")

        let savingManualHost = host(); savingManualHost.exitAfterRequest = false
        savingManualHost.beforeQuit = { savingManualHost.assertions = [] }
        let savingManual = BlockingApps.prepareForManualSleep(host: savingManualHost, deadline: 108, cancelled: { false })
        check(!savingManual.canProceedWithSleep && savingManual.remainingCount == 1
              && savingManual.requestedCount == 1 && savingManualHost.mainDispatches == 1,
              "An app that releases its assertion for a save prompt remains unresolved without repeated requests")
        print("PASS: blocking-app adapter typed assertions, guarded normal quit and real-outcome simulation — \(checks) checks; no real apps were queried or quit")
    }
}
