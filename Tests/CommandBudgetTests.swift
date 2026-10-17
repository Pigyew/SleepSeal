import Foundation

#if COMMAND_BUDGET_TESTS
// MacSystem is linked for its real subprocess implementation. No radio or power
// adapter is instantiated, and this fence prevents accidental power writes.
enum PrivilegedPowerTool {
    static func claimProtection() throws { fatalError("No power ownership in subprocess tests") }
    static func releaseProtection() throws { fatalError("No power ownership in subprocess tests") }
    static func verifyAuthorization() throws { fatalError("Command budget tests must never access power authorization") }
    static func set(scope: String, key: String, value: Int, restoring: Bool = false) throws {
        fatalError("Command budget tests must never change system power settings")
    }
}
#endif

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(description: message) }
}

@main
struct CommandBudgetTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("nested operations share one deadline", sharedDeadline),
            ("throwing operation restores thread-local context", contextCleanup),
            ("canceled budget rejects a subprocess before launch", canceledBudget),
            ("subprocess timeout ends within the shared budget", subprocessTimeout),
            ("ordinary output and exit status are captured", outputAndStatus),
            ("arguments pass literally without shell interpretation", literalArguments),
            ("verbose subprocess output is drained and bounded", boundedOutput)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) subprocess tests passed; only printf, false and sleep were executed.")
    }
    static func sharedDeadline() throws {
        try OperationBudget.perform(seconds: 1) {
            guard let outer = OperationBudget.current else { throw CheckFailure(description: "Missing outer deadline") }
            try OperationBudget.perform(seconds: 100) {
                try expect(OperationBudget.current === outer, "Nested operation reset the shared deadline")
                try expect(OperationBudget.current!.deadline == outer.deadline, "Nested operation extended its deadline")
            }
            try expect(OperationBudget.current === outer, "Nested operation lost the parent context")
        }
        try expect(OperationBudget.current == nil, "Operation context leaked after completion")
    }
    static func contextCleanup() throws {
        enum Deliberate: Error { case failure }
        do { try OperationBudget.perform(seconds: 1) { throw Deliberate.failure } }
        catch Deliberate.failure { }
        try expect(OperationBudget.current == nil, "Failed operation retained its budget context")
    }
    static func canceledBudget() throws {
        try OperationBudget.perform(seconds: 1) {
            OperationBudget.current!.cancel()
            do {
                _ = try command("/does-not-exist", [])
                throw CheckFailure(description: "Canceled budget allowed process launch")
            } catch let error as GuardFailure {
                try expect(error.description.contains("budget"), "Canceled operation tried to launch a process before checking its budget")
            }
        }
    }
    static func subprocessTimeout() throws {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try OperationBudget.perform(seconds: 0.2) { _ = try command("/bin/sleep", ["4"], timeout: 5) }
            throw CheckFailure(description: "Long-running process ignored the budget")
        } catch let error as GuardFailure {
            try expect(error.description.contains("timed out"), "Unexpected timeout error")
        }
        try expect(ProcessInfo.processInfo.systemUptime - start < 2, "Timeout consumed the child process's full duration")
    }
    static func outputAndStatus() throws {
        let printed = try command("/usr/bin/printf", ["%s", "SleepSeal check"])
        try expect(printed.status == 0 && printed.output == "SleepSeal check", "Subprocess output was lost")
        let failed = try command("/usr/bin/false", [])
        try expect(failed.status != 0, "Failure exit status was hidden")
    }
    static func literalArguments() throws {
        let value = "$(should-stay-literal);`also-literal` & | >"
        let result = try command("/usr/bin/printf", ["%s", value])
        try expect(result.output == value && result.status == 0, "Arguments underwent shell interpretation")
    }
    static func boundedOutput() throws {
        let result = try command("/usr/bin/printf", ["%0300000d", "0"], timeout: 3)
        try expect(result.status == 0, "Verbose child could not complete")
        try expect(result.output.utf8.count == 262_144, "Captured output did not respect its memory bound")
    }
}
