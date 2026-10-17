import AppKit
import CoreBluetooth
import Darwin

func runtimeReportPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SleepSeal/runtime-status.json").path
}
func writeReport(_ path: String, success: Bool, stage: String, message: String, snapshot: Snapshot? = nil, pending: PendingState? = nil, mostRecentFailure: String? = nil) throws {
    var report: [String: Any] = ["success": success, "stage": stage, "message": message,
        "timestamp": ISO8601DateFormatter().string(from: Date()), "version": "0.2.1 Beta",
        "bluetoothPermission": CBManager.authorization == .allowedAlways, "waitingForUnlock": pending != nil]
    if let snapshot { report["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    var client: AgentClient?
    var instanceFD: Int32 = -1
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        func value(_ key: String) -> String? { guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }; return arguments[index + 1] }
        let mock = arguments.contains("--ui-test") || arguments.contains("--ui-self-test")
        if mock {
            let controller = AppController(mock: true, language: UILanguage(rawValue: value("--language") ?? "en") ?? .english, page: DashboardPage(rawValue: value("--page") ?? "overview") ?? .overview)
            self.controller = controller; controller.start(existingInstallation: false, show: true)
            if let path = value("--ui-self-test") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    do { let count = try DashboardVerification.run(outputDirectory: URL(fileURLWithPath: path)); print("PASS: \(count) native UI checks; hardware adapters are mocked"); exit(0) }
                    catch { fputs("UI verification failed: \(error)\n", stderr); exit(1) }
                }
            } else if let path = value("--capture-directory") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    do { try controller.capture(to: URL(fileURLWithPath: path), appearance: value("--appearance") ?? "light"); exit(0) }
                    catch { fputs("\(error)\n", stderr); exit(1) }
                }
            }
            return
        }
        if arguments.contains("--watch") {
            do {
                let store = try JSONStore()
                let lockPath = store.url.deletingLastPathComponent().appendingPathComponent("instance.lock").path
                instanceFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
                guard instanceFD >= 0, flock(instanceFD, LOCK_EX | LOCK_NB) == 0 else { throw GuardFailure("SleepSeal is already running / SleepSeal 已在运行") }
                let controller = AppController()
                self.controller = controller
                let existing = FileManager.default.fileExists(atPath: store.url.path)
                controller.start(existingInstallation: existing, show: false)
            } catch {
                // Even a damaged recovery record or unavailable background
                // component must leave a usable repair dashboard.
                let controller = AppController(); self.controller = controller
                controller.model.serviceAvailable = false; controller.model.statusKey = "guard.error"; controller.model.detailKey = "guard.error.detail"
                controller.model.feedbackKey = "feedback.failed"; controller.model.feedbackDetail = RuntimeErrorPresentation.message(String(describing: error), languageCode: controller.model.language.localeIdentifier)
                controller.showDashboard()
            }
            return
        }
        // A normal launch is only a client. The user-domain launchd service is
        // the sole owner of the guard, menu and panel.
        client = AgentClient()
        client?.show { [weak self] ready in
            guard let self else { return }
            if ready { NSApp.terminate(nil); return }
            do {
                let store = AppConfigurationStore()
                if FileManager.default.fileExists(atPath: UserAgentInstallation.agentURL.path),
                   !FileManager.default.fileExists(atPath: store.fileURL.path) {
                    let data = try Data(contentsOf: UserAgentInstallation.agentURL)
                    let old = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                    let args = old?["ProgramArguments"] as? [String] ?? []
                    if !args.contains(CommandLine.arguments[0]) || !((old?["MachServices"] as? [String: Any])?[AgentIdentity.service] as? Bool ?? false) {
                        try store.save(AppConfiguration(existingInstallation: true))
                    }
                }
                let config = try store.load()
                try UserAgentInstallation.install(executable: Bundle.main.executableURL!.path, login: config.launchAtLogin, replaceLegacy: true)
                self.connectAfterStart(attempts: 10)
            } catch {
                let controller = AppController(); self.controller = controller
                controller.model.serviceAvailable = false; controller.model.statusKey = "guard.error"; controller.model.detailKey = "guard.error.detail"
                controller.model.feedbackKey = "feedback.failed"; controller.model.feedbackDetail = RuntimeErrorPresentation.message(String(describing: error), languageCode: controller.model.language.localeIdentifier)
                controller.showDashboard()
            }
        }
    }
    private func connectAfterStart(attempts: Int) {
        client = AgentClient()
        client?.show { [weak self] ready in
            guard let self else { return }
            if ready { NSApp.terminate(nil) }
            else if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connectAfterStart(attempts: attempts - 1) } }
            else {
                let controller = AppController(); self.controller = controller
                controller.model.serviceAvailable = false; controller.model.statusKey = "guard.error"; controller.model.detailKey = "guard.error.detail"
                controller.model.feedbackKey = "feedback.failed"; controller.model.feedbackDetail = "Background service unavailable. Reopen the installed app to retry. / 后台服务不可用，请重新打开已安装应用重试。"
                controller.showDashboard()
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, !controller.canTerminate else { return .terminateNow }
        controller.requestQuit(); return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct Main {
    @MainActor static func main() {
        guard getuid() != 0 else { fputs("Run SleepSeal as the logged-in user / 请使用普通用户运行\n", stderr); exit(1) }
        if CommandLine.arguments.contains("--doctor") {
            do { print("SleepSeal 0.2.1 Beta — read only"); let p = try MacPowerPreferencesAdapter().read(); for v in p.values { print("\(v.id)=\(v.value)") }; return }
            catch { fputs("\(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let delegate = ApplicationDelegate()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
}
