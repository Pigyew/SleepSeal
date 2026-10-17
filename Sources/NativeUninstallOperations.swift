import Foundation
import Darwin

/// User-domain staging precedes privileged deletion. Paths/commands can be
/// injected for filesystem integration checks without touching an installation.
final class NativeUninstallOperations: UninstallOperations {
    private let agentURL: URL
    private let stagedURL: URL
    private let domain: String
    private let verify: () throws -> Void
    private let run: (String, [String], TimeInterval) throws -> CommandResult

    init(agentURL: URL = UserAgentInstallation.agentURL, domain: String = UserAgentInstallation.domain,
         verify: @escaping () throws -> Void = PrivilegedPowerTool.verifyInstallation,
         run: @escaping (String, [String], TimeInterval) throws -> CommandResult = { try command($0, $1, timeout: $2) }) {
        self.agentURL = agentURL
        self.stagedURL = agentURL.appendingPathExtension("uninstall-staged")
        self.domain = domain; self.verify = verify; self.run = run
    }

    private func exists(_ url: URL) throws -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return false }
            throw GuardFailure("Cannot inspect login startup / 无法检查登录启动项")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid() else {
            throw GuardFailure("Login startup is not a regular user-owned file; it was preserved / 登录启动项不是当前用户的普通文件，已保留")
        }
        return true
    }

    func stageUserAgent() throws {
        // Recover staging left by a precommit interruption before trying again.
        if try exists(stagedURL) { try restoreUserAgent() }
        if try exists(agentURL) { try FileManager.default.moveItem(at: agentURL, to: stagedURL) }
    }
    func restoreUserAgent() throws {
        guard try exists(stagedURL) else { return }
        if try exists(agentURL) {
            guard try Data(contentsOf: agentURL) == Data(contentsOf: stagedURL) else {
                throw GuardFailure("Login startup changed during uninstall; both copies were preserved / 卸载期间登录启动项被修改，已保留两个副本")
            }
            try FileManager.default.removeItem(at: stagedURL)
        } else { try FileManager.default.moveItem(at: stagedURL, to: agentURL) }
    }
    func removePrivilegedInstallation() throws {
        try verify()
        let result = try run("/usr/bin/sudo", ["-n", PrivilegedPowerTool.path, "uninstall"], 10)
        guard result.status == 0 else { throw GuardFailure(result.output) }
    }
    func finishUserCleanup() throws {
        if try exists(stagedURL) { try FileManager.default.removeItem(at: stagedURL) }
        let result = try run("/bin/launchctl", ["bootout", "\(domain)/\(AgentIdentity.label)"], 5)
        // ESRCH means the user service has already stopped, including a retry.
        guard result.status == 0 || result.status == ESRCH else {
            throw GuardFailure("Uninstall removed authorization; login-service cleanup needs retry / 卸载已移除授权，登录服务清理需要重试")
        }
    }
}
