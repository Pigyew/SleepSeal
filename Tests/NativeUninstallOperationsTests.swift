import Foundation
import Darwin

// Link only the real uninstall adapter and coordinator. Every command and
// installation check must be explicitly injected; defaults fail closed.
enum AgentIdentity { static let label = "local.sleepseal.guard" }
enum UserAgentInstallation {
    static var agentURL: URL { fatalError("Native uninstall tests must inject a temporary LaunchAgent path") }
    static var domain: String { fatalError("Native uninstall tests must inject a fixture domain") }
}
enum PrivilegedPowerTool {
    static let path = "/mock/SleepSeal.PowerControl"
    static func verifyInstallation() throws { fatalError("Native uninstall tests must inject installation verification") }
}
struct CommandResult { let status: Int32; let output: String }
struct GuardFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func command(_ path: String, _ args: [String], timeout: TimeInterval = 2) throws -> CommandResult {
    fatalError("Native uninstall tests must never execute sudo or launchctl")
}

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(description: message) }
}
private func rejects(_ action: () throws -> Void) throws {
    do { try action() }
    catch { return }
    throw CheckFailure(description: "An unsafe or failing uninstall operation unexpectedly succeeded")
}

private final class Fixture {
    let directory: URL
    let agent: URL
    let staged: URL
    let original = Data("fixture LaunchAgent bytes\n".utf8)
    var verificationCount = 0
    var failVerification = false
    var commands: [(String, [String], TimeInterval)] = []
    var rootStatus: Int32 = 0
    var cleanupStatus: Int32 = 0
    var failCleanupLaunch = false

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SleepSeal-native-uninstall-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        agent = directory.appendingPathComponent("local.sleepseal.guard.plist")
        staged = agent.appendingPathExtension("uninstall-staged")
        try original.write(to: agent, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agent.path)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func operations() -> NativeUninstallOperations {
        NativeUninstallOperations(agentURL: agent, domain: "gui/mock-user", verify: { [unowned self] in
            self.verificationCount += 1
            if self.failVerification { throw CheckFailure(description: "injected verification failure") }
        }, run: { [unowned self] path, args, timeout in
            self.commands.append((path, args, timeout))
            if path == "/usr/bin/sudo" { return CommandResult(status: self.rootStatus, output: "injected root result") }
            if path == "/bin/launchctl" {
                if self.failCleanupLaunch { throw CheckFailure(description: "injected cleanup launch failure") }
                return CommandResult(status: self.cleanupStatus, output: "injected cleanup result")
            }
            throw CheckFailure(description: "Unexpected injected command: \(path)")
        })
    }
    func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }
}

@main struct NativeUninstallOperationsTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("native stage and restore preserve bytes and permissions", stageRoundTrip),
            ("agent symlink is rejected before root work", agentSymlink),
            ("staged symlink is rejected without changing startup", stagedSymlink),
            ("restore rejects a replacement agent symlink", restoreSymlink),
            ("restore retains conflicting startup copies", conflictingRestore),
            ("precommit staging interruption can be restaged", interruptedStaging),
            ("helper failure restores the actual staged file", helperFailure),
            ("verification failure restores staging without any command", verificationFailure),
            ("cleanup retry never repeats root removal and accepts a stopped service", cleanupRetry),
            ("cleanup command launch failure remains committed and retryable", cleanupLaunchFailure)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) native uninstall integration scenarios passed with temporary files and injected commands; no installations or services changed.")
    }

    static func stageRoundTrip() throws {
        let fixture = try Fixture(), operations = fixture.operations()
        try operations.stageUserAgent()
        let stagedBytes = try fixture.bytes(fixture.staged)
        try expect(!fixture.exists(fixture.agent) && stagedBytes == fixture.original, "Staging lost the original startup file")
        try operations.restoreUserAgent()
        let restoredBytes = try fixture.bytes(fixture.agent)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.agent.path)[.posixPermissions] as? NSNumber
        try expect(restoredBytes == fixture.original && !fixture.exists(fixture.staged) && permissions?.intValue == 0o600,
                   "Restoration changed startup bytes or permissions")
        try expect(fixture.commands.isEmpty && fixture.verificationCount == 0, "Filesystem staging invoked privileged work")
    }

    static func agentSymlink() throws {
        let fixture = try Fixture()
        let target = fixture.directory.appendingPathComponent("target.plist")
        try FileManager.default.moveItem(at: fixture.agent, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.agent, withDestinationURL: target)
        let coordinator = UninstallCoordinator(operations: fixture.operations())
        try rejects { _ = try coordinator.uninstall() }
        let bytes = try fixture.bytes(target)
        try expect(fixture.isSymlink(fixture.agent) && bytes == fixture.original && !fixture.exists(fixture.staged),
                   "Rejected startup symlink or its target was changed")
        try expect(fixture.commands.isEmpty && fixture.verificationCount == 0 && !coordinator.irreversibleCommitted,
                   "Root work ran after an unsafe startup file")
    }

    static func stagedSymlink() throws {
        let fixture = try Fixture()
        let target = fixture.directory.appendingPathComponent("staged-target")
        try Data("preserved target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.staged, withDestinationURL: target)
        let coordinator = UninstallCoordinator(operations: fixture.operations())
        try rejects { _ = try coordinator.uninstall() }
        let original = try fixture.bytes(fixture.agent), targetBytes = try fixture.bytes(target)
        try expect(original == fixture.original && fixture.isSymlink(fixture.staged) && targetBytes == Data("preserved target".utf8),
                   "Rejected staged symlink changed either file")
        try expect(fixture.commands.isEmpty && fixture.verificationCount == 0, "Root work ran after unsafe staging")
    }

    static func restoreSymlink() throws {
        let fixture = try Fixture(), operations = fixture.operations()
        try operations.stageUserAgent()
        let target = fixture.directory.appendingPathComponent("replacement-target")
        try Data("external startup".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.agent, withDestinationURL: target)
        try rejects { try operations.restoreUserAgent() }
        let stagedBytes = try fixture.bytes(fixture.staged), targetBytes = try fixture.bytes(target)
        try expect(fixture.isSymlink(fixture.agent) && stagedBytes == fixture.original && targetBytes == Data("external startup".utf8),
                   "Rejected restoration changed a replacement symlink or target")
    }

    static func conflictingRestore() throws {
        let fixture = try Fixture(), operations = fixture.operations()
        try operations.stageUserAgent()
        let replacement = Data("external replacement".utf8)
        try replacement.write(to: fixture.agent)
        try rejects { try operations.restoreUserAgent() }
        let current = try fixture.bytes(fixture.agent), staged = try fixture.bytes(fixture.staged)
        try expect(current == replacement && staged == fixture.original, "A restoration conflict overwrote one copy")
    }

    static func interruptedStaging() throws {
        let fixture = try Fixture()
        try fixture.operations().stageUserAgent()
        let restarted = fixture.operations()
        try restarted.stageUserAgent()
        let staged = try fixture.bytes(fixture.staged)
        try expect(staged == fixture.original && !fixture.exists(fixture.agent), "Restart could not normalize old staging")
        try restarted.restoreUserAgent()
        let restored = try fixture.bytes(fixture.agent)
        try expect(restored == fixture.original && !fixture.exists(fixture.staged), "Restaged startup could not be restored")
    }

    static func helperFailure() throws {
        let fixture = try Fixture(); fixture.rootStatus = 64
        let coordinator = UninstallCoordinator(operations: fixture.operations())
        try rejects { _ = try coordinator.uninstall() }
        let restored = try fixture.bytes(fixture.agent)
        try expect(restored == fixture.original && !fixture.exists(fixture.staged) && !coordinator.irreversibleCommitted,
                   "Helper failure did not restore native staging")
        try expect(fixture.verificationCount == 1 && fixture.commands.count == 1, "Helper failure unexpectedly attempted cleanup")
        let invoked = fixture.commands[0]
        try expect(invoked.0 == "/usr/bin/sudo" && invoked.1 == ["-n", PrivilegedPowerTool.path, "uninstall"] && invoked.2 == 10,
                   "Privileged adapter changed the fixed uninstall request")
    }

    static func verificationFailure() throws {
        let fixture = try Fixture(); fixture.failVerification = true
        let coordinator = UninstallCoordinator(operations: fixture.operations())
        try rejects { _ = try coordinator.uninstall() }
        let restored = try fixture.bytes(fixture.agent)
        try expect(restored == fixture.original && !fixture.exists(fixture.staged) && fixture.commands.isEmpty,
                   "Verification failure did not preserve startup or invoked a command")
    }

    static func cleanupRetry() throws {
        let fixture = try Fixture(); fixture.cleanupStatus = 5
        let coordinator = UninstallCoordinator(operations: fixture.operations())
        let initial = try coordinator.uninstall()
        guard case .cleanupRequired = initial else { throw CheckFailure(description: "Native cleanup failure was hidden") }
        try expect(coordinator.irreversibleCommitted && !fixture.exists(fixture.agent) && !fixture.exists(fixture.staged),
                   "Postcommit cleanup failure restored or retained login startup")
        fixture.cleanupStatus = ESRCH
        let retried = try coordinator.uninstall()
        try expect(retried == .removed && fixture.verificationCount == 1 && fixture.commands.map { $0.0 } == ["/usr/bin/sudo", "/bin/launchctl", "/bin/launchctl"],
                   "Native cleanup retry repeated privileged deletion or rejected an already stopped service")
        try expect(fixture.commands[1].1 == ["bootout", "gui/mock-user/local.sleepseal.guard"] && fixture.commands[1].2 == 5,
                   "Cleanup adapter changed the fixed user-domain request")
        _ = try coordinator.uninstall()
        try expect(fixture.commands.count == 3, "Completed native cleanup was repeated")
    }

    static func cleanupLaunchFailure() throws {
        let fixture = try Fixture(); fixture.failCleanupLaunch = true
        let coordinator = UninstallCoordinator(operations: fixture.operations())
        let initial = try coordinator.uninstall()
        guard case .cleanupRequired(let message) = initial else { throw CheckFailure(description: "Cleanup launch failure escaped the committed outcome") }
        try expect(message.contains("injected cleanup launch failure") && coordinator.irreversibleCommitted,
                   "Cleanup launch failure lost its committed state or diagnostic")
        fixture.failCleanupLaunch = false
        let retried = try coordinator.uninstall()
        try expect(retried == .removed && fixture.verificationCount == 1 && fixture.commands.count == 3,
                   "Cleanup launch retry re-entered privileged removal")
    }
}
