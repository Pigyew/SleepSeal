import Foundation
import Security
import Darwin

@objc protocol SleepSealControlProtocol {
    func showDashboard(withReply reply: @escaping (Bool) -> Void)
}

enum AgentIdentity {
    static let label = "local.sleepseal.guard"
    static let service = "local.sleepseal.guard.control"
    static func requirement() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw GuardFailure("Cannot identify signed application / 无法验证应用签名") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw GuardFailure("Cannot verify current build / 无法验证当前构建") }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { throw GuardFailure("Missing code requirement / 缺少代码签名要求") }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { throw GuardFailure("Invalid code requirement / 签名要求无效") }
        return text as String
    }
    static func accepts(euid: uid_t, ownUID: uid_t, hasRequirement: Bool) -> Bool { euid == ownUID && hasRequirement }
}

final class AgentListener: NSObject, NSXPCListenerDelegate, SleepSealControlProtocol {
    private let listener: NSXPCListener
    private let show: () -> Void
    init(show: @escaping () -> Void) throws {
        self.show = show
        listener = NSXPCListener(machServiceName: AgentIdentity.service)
        super.init()
        listener.setConnectionCodeSigningRequirement(try AgentIdentity.requirement())
        listener.delegate = self
    }
    func start() { listener.resume() }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // launchd and Foundation enforce the current build requirement before
        // this delegate is called. Never fall back to PID or Bundle ID checks.
        guard AgentIdentity.accepts(euid: connection.effectiveUserIdentifier, ownUID: getuid(), hasRequirement: true) else { return false }
        connection.exportedInterface = NSXPCInterface(with: SleepSealControlProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func showDashboard(withReply reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { self.show(); reply(true) }
    }
}

final class AgentClient {
    private var connection: NSXPCConnection?
    private var finished = false
    func show(completion: @escaping (Bool) -> Void) {
        func finish(_ result: Bool) {
            DispatchQueue.main.async {
                guard !self.finished else { return }; self.finished = true
                self.connection?.invalidate(); self.connection = nil
                completion(result)
            }
        }
        do {
            let connection = NSXPCConnection(machServiceName: AgentIdentity.service)
            connection.setCodeSigningRequirement(try AgentIdentity.requirement())
            connection.remoteObjectInterface = NSXPCInterface(with: SleepSealControlProtocol.self)
            connection.invalidationHandler = { finish(false) }
            self.connection = connection
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(false) } as? SleepSealControlProtocol
            proxy?.showDashboard { success in
                finish(success && connection.effectiveUserIdentifier == getuid())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
        } catch { finish(false) }
    }
}

/// All user-domain files are created by the logged-in user, never the package's root scripts.
enum UserAgentInstallation {
    static var agentURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.sleepseal.guard.plist") }
    static var domain: String { "gui/\(getuid())" }
    static func install(executable: String, login: Bool, replaceLegacy: Bool = false) throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw GuardFailure("Application is missing / 找不到应用程序") }
        // A replacement stops the old process, releasing the same instance lock;
        // it does not delete pending.json, the previous application or its rule.
        if replaceLegacy { _ = try command("/bin/launchctl", ["bootout", "\(domain)/\(AgentIdentity.label)"], timeout: 5) }
        let plist: [String: Any] = ["Label": AgentIdentity.label, "ProgramArguments": [executable, "--watch"],
            "RunAtLoad": login, "KeepAlive": ["SuccessfulExit": false, "AfterInitialDemand": true],
            "LimitLoadToSessionType": "Aqua", "AssociatedBundleIdentifiers": ["local.sleepseal.guard"],
            "MachServices": [AgentIdentity.service: true], "ProcessType": "Interactive",
            "ThrottleInterval": 10]
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentURL.path)
        _ = try command("/bin/launchctl", ["bootstrap", domain, agentURL.path], timeout: 5)
        let result = try command("/bin/launchctl", ["kickstart", "\(domain)/\(AgentIdentity.label)"], timeout: 5)
        guard result.status == 0 else { throw GuardFailure("Background service could not start / 无法启动后台服务：\(result.output)") }
    }
    static func updateLogin(_ enabled: Bool) throws {
        guard let data = try? Data(contentsOf: agentURL), var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw GuardFailure("Reopen the installed app to repair login startup / 请重新打开已安装应用修复登录自启") }
        plist["RunAtLoad"] = enabled
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentURL.path)
    }
    static func removeOwnAgentFile() throws {
        if FileManager.default.fileExists(atPath: agentURL.path) { try FileManager.default.removeItem(at: agentURL) }
    }
}
