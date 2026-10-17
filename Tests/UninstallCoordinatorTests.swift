import Foundation

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure(description: message) }
}

private final class MockUninstallOperations: UninstallOperations {
    var calls: [String] = []
    var failures: Set<String> = []
    var agentAvailable = true
    var staged = false
    var privilegedAvailable = true
    var beforeCleanup: (() throws -> Void)?

    private func record(_ name: String) throws {
        calls.append(name)
        if failures.contains(name) { throw TestFailure(description: "injected \(name) failure") }
    }
    func stageUserAgent() throws {
        try record("stage")
        agentAvailable = false; staged = true
    }
    func restoreUserAgent() throws {
        try record("restore")
        agentAvailable = true; staged = false
    }
    func removePrivilegedInstallation() throws {
        try record("privileged")
        privilegedAvailable = false
    }
    func finishUserCleanup() throws {
        try beforeCleanup?()
        try record("cleanup")
        staged = false
    }
}

@main struct UninstallCoordinatorTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("failed staging leaves privileged installation untouched", stageFailure),
            ("helper failure restores staged startup", privilegedFailure),
            ("failed rollback is reported and retried before root work", rollbackFailure),
            ("cleanup failure retains commit and retries cleanup only", cleanupFailure),
            ("repeated cleanup failures never retry privileged removal", repeatedCleanupFailure),
            ("complete uninstall is ordered and idempotent", successfulRemoval)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) uninstall transaction scenarios passed using mocks; no files or services were removed.")
    }

    static func stageFailure() throws {
        let operations = MockUninstallOperations(); operations.failures = ["stage"]
        let coordinator = UninstallCoordinator(operations: operations)
        do { _ = try coordinator.uninstall(); throw TestFailure(description: "Staging failure was hidden") }
        catch let error as TestFailure {
            try expect(error.description == "injected stage failure", "Wrong staging error")
        }
        try expect(operations.calls == ["stage"], "Root or cleanup work ran after failed staging")
        try expect(operations.agentAvailable && operations.privilegedAvailable && !operations.staged,
                   "Failed staging changed the installation")
        try expect(!coordinator.irreversibleCommitted, "Staging failure was marked committed")
        operations.failures = []
        let retried = try coordinator.uninstall()
        try expect(retried == .removed && coordinator.irreversibleCommitted, "Staging failure could not be retried")
    }

    static func privilegedFailure() throws {
        let operations = MockUninstallOperations(); operations.failures = ["privileged"]
        let coordinator = UninstallCoordinator(operations: operations)
        do { _ = try coordinator.uninstall(); throw TestFailure(description: "Helper failure was hidden") }
        catch let error as TestFailure {
            try expect(error.description == "injected privileged failure", "Wrong helper error")
        }
        try expect(operations.calls == ["stage", "privileged", "restore"], "Staged startup was not restored in order")
        try expect(operations.agentAvailable && operations.privilegedAvailable && !operations.staged,
                   "Helper failure did not retain a usable installation")
        try expect(!coordinator.irreversibleCommitted, "Helper failure was marked committed")
        operations.failures = []
        let retried = try coordinator.uninstall()
        try expect(retried == .removed && operations.calls == ["stage", "privileged", "restore", "stage", "privileged", "cleanup"],
                   "Precommit retry did not stage and remove normally")
    }

    static func rollbackFailure() throws {
        let operations = MockUninstallOperations(); operations.failures = ["privileged", "restore"]
        let coordinator = UninstallCoordinator(operations: operations)
        do { _ = try coordinator.uninstall(); throw TestFailure(description: "Rollback failure was hidden") }
        catch let error as UninstallPrecommitFailure {
            try expect(error.description.contains("injected privileged failure") && error.description.contains("injected restore failure"),
                       "Rollback error discarded one failure")
        }
        try expect(!coordinator.irreversibleCommitted && operations.staged && operations.privilegedAvailable,
                   "Failed rollback changed the commit boundary")
        do { _ = try coordinator.uninstall(); throw TestFailure(description: "Unresolved rollback was ignored") }
        catch let error as TestFailure {
            try expect(error.description == "injected restore failure", "Wrong unresolved rollback error")
        }
        try expect(operations.calls == ["stage", "privileged", "restore", "restore"],
                   "Root work retried before resolving staged startup")
        operations.failures = []
        let retried = try coordinator.uninstall()
        try expect(retried == .removed && operations.calls.suffix(4) == ["restore", "stage", "privileged", "cleanup"],
                   "Rollback repair could not complete uninstall")
    }

    static func cleanupFailure() throws {
        let operations = MockUninstallOperations(); operations.failures = ["cleanup"]
        let coordinator = UninstallCoordinator(operations: operations)
        operations.beforeCleanup = {
            try expect(coordinator.irreversibleCommitted, "Cleanup started before the irreversible commit flag was set")
        }
        let outcome = try coordinator.uninstall()
        try expect(outcome == .cleanupRequired("injected cleanup failure"), "Postcommit failure was thrown or hidden")
        try expect(coordinator.irreversibleCommitted && !operations.privilegedAvailable && !operations.agentAvailable,
                   "Postcommit failure restored or re-enabled the installation")
        try expect(operations.calls == ["stage", "privileged", "cleanup"], "Postcommit failure rolled startup back")
        operations.failures = []
        let retried = try coordinator.uninstall()
        try expect(retried == .removed && operations.calls == ["stage", "privileged", "cleanup", "cleanup"],
                   "Cleanup retry repeated root work or staging")
    }

    static func repeatedCleanupFailure() throws {
        let operations = MockUninstallOperations(); operations.failures = ["cleanup"]
        let coordinator = UninstallCoordinator(operations: operations)
        for _ in 0..<3 {
            let outcome = try coordinator.uninstall()
            try expect(outcome == .cleanupRequired("injected cleanup failure") && coordinator.irreversibleCommitted,
                       "Repeated cleanup failure lost its committed status")
        }
        try expect(operations.calls == ["stage", "privileged", "cleanup", "cleanup", "cleanup"],
                   "Repeated cleanup retried root removal or restored startup")
    }

    static func successfulRemoval() throws {
        let operations = MockUninstallOperations()
        let coordinator = UninstallCoordinator(operations: operations)
        let outcome = try coordinator.uninstall()
        try expect(outcome == .removed && coordinator.irreversibleCommitted, "Successful removal was not committed")
        try expect(operations.calls == ["stage", "privileged", "cleanup"], "Uninstall ran in the wrong order")
        try expect(!operations.agentAvailable && !operations.privilegedAvailable && !operations.staged,
                   "Successful removal left installation state behind")
        let repeated = try coordinator.uninstall()
        try expect(repeated == .removed && operations.calls == ["stage", "privileged", "cleanup"],
                   "Completed uninstall was not idempotent")
    }
}
