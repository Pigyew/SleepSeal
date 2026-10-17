import AppKit
import CoreBluetooth
import IOKit
import IOKit.pwr_mgt
import Darwin

// IOKit/IOMessage.h macros are not imported by Swift. These are their ABI values.
private let canSystemSleep: UInt32 = 0xe0000270
private let systemWillSleep: UInt32 = 0xe0000280
private let systemHasPoweredOn: UInt32 = 0xe0000300

func writeReport(_ path: String, success: Bool, stage: String, message: String,
                 snapshot: Snapshot? = nil, pending: PendingState? = nil, mostRecentFailure: String? = nil) throws {
    var report: [String: Any] = [
        "success": success, "stage": stage, "message": message,
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "pid": ProcessInfo.processInfo.processIdentifier,
        "bluetoothPermission": CBManager.authorization == .allowedAlways,
        "waitingForUnlock": pending != nil,
        "sawLock": pending?.sawLock ?? false,
        "restorationAuthorized": pending?.restorationAuthorized ?? false
    ]
    if let snapshot {
        report["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
    }
    report["hotCorners"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HotCorners.read()))
    if let mostRecentFailure { report["mostRecentFailure"] = mostRecentFailure }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

func runtimeReportPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SleepSeal/runtime-status.json").path
}

final class Acknowledgement {
    private let lock = NSLock()
    private var done = false
    private let port: io_connect_t
    private let argument: Int
    init(port: io_connect_t, argument: Int) { self.port = port; self.argument = argument }
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        IOAllowPowerChange(port, argument)
    }
}

final class Watcher: NSObject {
    let engine: SleepGuard
    let transitions: SleepTransitions
    let queue = DispatchQueue(label: "local.sleepseal.state")
    private var powerPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var timer: DispatchSourceTimer?
    private var mostRecentFailure: String?
    private var screenLockedObserved = false

    init(engine: SleepGuard) {
        self.engine = engine
        self.transitions = SleepTransitions(engine: engine)
        self.screenLockedObserved = ConsoleSession.locked ||
            (engine.pending?.sawLock == true && engine.pending?.restorationAuthorized != true)
    }

    func perform(_ name: String, _ action: () throws -> Void) {
        do {
            try action()
            log(name)
            report(success: true, stage: name, message: "完成")
        } catch {
            mostRecentFailure = "\(ISO8601DateFormatter().string(from: Date())) \(name)：\(error)"
            log("\(name)失败：\(error)")
            report(success: false, stage: name, message: String(describing: error))
        }
    }

    func report(success: Bool, stage: String, message: String) {
        do {
            try writeReport(runtimeReportPath(), success: success, stage: stage, message: message,
                snapshot: try? MacSystem().capture(), pending: engine.pending, mostRecentFailure: mostRecentFailure)
        } catch { log("诊断记录写入失败：\(error)") }
    }

    func start() throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerPort = IORegisterForSystemPower(context, &notificationPort, { context, _, type, argument in
            guard let context else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue()
            watcher.powerEvent(type, Int(bitPattern: argument))
        }, &notifier)
        guard powerPort != 0, let notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() else {
            throw GuardFailure("无法注册睡眠事件")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(locked), name: .init("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(displaySlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displayWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        // Fast user switching is deliberately not an unlock signal.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.engine.pending != nil else { return }
            if ConsoleSession.locked {
                self.screenLockedObserved = true
                self.perform("确认锁定") { try self.engine.didLock() }
            }
            self.perform("核对守护状态") { try self.engine.reconcile(sessionVerified: ConsoleSession.verified) }
        }
        timer.resume()
        self.timer = timer
        queue.async {
            self.report(success: true, stage: "ready", message: "已注册系统睡眠、显示器睡眠与解锁事件；尚未切换设置")
            if ConsoleSession.locked { self.perform("确认锁定") { try self.engine.didLock() } }
            // A restart never treats an already visible desktop as a new unlock.
            if self.engine.pending != nil {
                self.perform("恢复守护") { try self.engine.reconcile(sessionVerified: ConsoleSession.verified) }
            }
        }
        log("守护已启动；监听系统和显示器睡眠（含触发角与闲置自动睡眠），仅解锁后恢复")
    }

    func powerEvent(_ type: UInt32, _ argument: Int) {
        if type == canSystemSleep {
            IOAllowPowerChange(powerPort, argument)
        } else if type == systemWillSleep {
            let ack = Acknowledgement(port: powerPort, argument: argument)
            // Return the sleep acknowledgement even if a system API stalls.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { ack.finish() }
            queue.async {
                defer { ack.finish() }
                self.perform("系统睡眠前处理") {
                    try self.transitions.sleep(.system, sessionLocked: ConsoleSession.locked || self.screenLockedObserved)
                }
            }
        } else if type == systemHasPoweredOn {
            queue.async {
                self.perform("系统唤醒后核对") { try self.transitions.wake(.system, sessionVerified: ConsoleSession.verified) }
            }
        }
    }

    @objc private func displaySlept(_ note: Notification) {
        queue.async {
            self.perform("显示器睡眠处理（含触发角和闲置）") {
                try self.transitions.sleep(.display, sessionLocked: ConsoleSession.locked || self.screenLockedObserved)
            }
        }
    }

    @objc private func displayWoke(_ note: Notification) {
        queue.async {
            self.perform("显示器唤醒后核对") {
                try self.transitions.wake(.display, sessionVerified: ConsoleSession.verified)
            }
        }
    }

    @objc private func locked(_ note: Notification) {
        queue.async {
            self.screenLockedObserved = true
            self.perform("收到锁屏事件") { try self.engine.didLock() }
        }
    }

    @objc private func unlocked(_ note: Notification) {
        // Session properties can trail the distributed notification briefly.
        queue.async {
            self.screenLockedObserved = false
            guard let gateID = self.engine.pending?.id else { return }
            for delay in [0.15, 0.6, 1.5] {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    guard self.engine.pending?.id == gateID else { return }
                    self.perform("检查解锁并恢复") { try self.engine.didUnlock(sessionVerified: ConsoleSession.verified) }
                }
            }
        }
    }
}

final class PermissionRequest: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager!
    private let reportPath: String?
    private var finished = false
    init(reportPath: String?) {
        self.reportPath = reportPath
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.finish(success: false, message: "蓝牙授权等待超时，请重新安装并完成系统授权")
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        DispatchQueue.main.async {
            let allowed = CBManager.authorization == .allowedAlways
            self.finish(success: allowed, message: allowed ? "蓝牙权限已允许"
                : "请在系统设置 → 隐私与安全性 → 蓝牙中允许 SleepSeal，然后重新安装")
        }
    }

    private func finish(success: Bool, message: String) {
        guard !finished else { return }
        finished = true
        if let reportPath {
            do { try writeReport(reportPath, success: success, stage: "bluetooth-permission", message: message) }
            catch { log("权限结果写入失败：\(error)") }
        } else { log(message) }
        // No extra success dialog: the installer receives the result and continues.
        NSApplication.shared.terminate(nil)
    }
}

@main struct Main {
    static func main() {
        guard getuid() != 0 else { fputs("请使用普通用户运行，不能以 root 运行。\n", stderr); exit(1) }
        let option = CommandLine.arguments.dropFirst().first ?? "--help"
        let reportPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
        if ["--preflight-report", "--recover-report"].contains(option) {
            guard let reportPath, reportPath.hasPrefix("/") else {
                log("需要绝对路径的检查结果文件"); exit(1)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                do {
                    if option == "--preflight-report" {
                        let snapshot = try preflight()
                        try writeReport(reportPath, success: true, stage: "preflight", message: "检查通过；未修改设置", snapshot: snapshot)
                    } else {
                        try recover()
                        try writeReport(reportPath, success: true, stage: "recovery", message: "原设置已恢复")
                    }
                } catch {
                    try? writeReport(reportPath, success: false, stage: option, message: String(describing: error))
                    log("检查或恢复失败：\(error)")
                }
                NSApplication.shared.terminate(nil)
            }
            NSApplication.shared.run()
            return
        }
        if option == "--check-permission" {
            guard CBManager.authorization == .allowedAlways else {
                fputs("尚未允许蓝牙权限；请在系统设置中允许 SleepSeal 后重新安装。\n", stderr)
                exit(1)
            }
            return
        }
        if option == "--preflight" {
            do {
                _ = try preflight()
                print("安装前检查通过；未切换无线或电源设置。")
            } catch { log("安装前检查失败：\(error)"); exit(1) }
            return
        }
        if option == "--permissions" {
            NSApplication.shared.setActivationPolicy(.accessory)
            let request = PermissionRequest(reportPath: reportPath)
            withExtendedLifetime(request) { NSApplication.shared.run() }
            return
        }
        if option == "--doctor" {
            let system = MacSystem()
            print("SleepSeal 0.1.2 — 只读检查（终端进程的权限归属可能不同，请优先使用 Check.command）")
            print("蓝牙控制接口：\(system.bluetooth.available ? "可用" : "不可用")")
            print("蓝牙权限：\(CBManager.authorization == .allowedAlways ? "已允许" : "尚未允许；请运行安装程序")")
            print("当前用户会话：\(ConsoleSession.verified ? "已登录且未锁定" : "锁定或无法确认")")
            do {
                let values = try system.powerValues()
                for value in values { print("\(value.scope) \(value.key) = \(value.value)") }
                print("深度休眠：由 macOS 管理；不修改 hibernatemode")
                for value in values where ["powermode", "lowpowermode"].contains(value.key) {
                    let permission = try command("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", value.scope, value.key, "1"])
                    print("\(value.scope) 低电量模式权限：\(permission.status == 0 ? "已配置" : "未配置")")
                }
            } catch { print("检查失败：\(error)"); exit(1) }
            return
        }
        guard option == "--watch" || option == "--recover" else {
            print("SleepSeal：--doctor 只读检查；--watch 后台守护；--recover 解锁后手动恢复；--permissions 申请蓝牙权限")
            return
        }
        do {
            NSApplication.shared.setActivationPolicy(.accessory)
            let store = try JSONStore()
            // The lock also prevents a manual recovery racing the live watcher.
            let lockPath = store.url.deletingLastPathComponent().appendingPathComponent("instance.lock").path
            let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw GuardFailure("守护进程正在运行；手动恢复请使用 Restore.command")
            }
            defer { flock(lockFD, LOCK_UN); close(lockFD) }
            let engine = try SleepGuard(system: MacSystem(), store: store)
            if option == "--recover" {
                try engine.recover(sessionVerified: ConsoleSession.verified)
                print("已恢复保存的设置。")
                return
            }
            let watcher = Watcher(engine: engine)
            _ = try preflight()
            try watcher.start()
            withExtendedLifetime(watcher) { NSApplication.shared.run() }
        } catch {
            try? writeReport(runtimeReportPath(), success: false, stage: "startup-failed", message: String(describing: error))
            log("启动或恢复失败：\(error)"); exit(1)
        }
    }

    static func preflight() throws -> Snapshot {
        guard CBManager.authorization == .allowedAlways else { throw GuardFailure("当前应用进程的蓝牙权限未允许") }
        let snapshot = try MacSystem().capture()
        for value in snapshot.power {
            for target in Set([value.value, PowerPolicy.desired(value)]) {
                let result = try command("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", value.scope, value.key, String(target)])
                guard result.status == 0 else {
                    throw GuardFailure("电源权限未就绪：\(value.scope) \(value.key)")
                }
            }
        }
        return snapshot
    }

    static func recover() throws {
        let store = try JSONStore()
        guard try store.load() != nil else { return }
        let lockPath = store.url.deletingLastPathComponent().appendingPathComponent("instance.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw GuardFailure("请先停止后台守护再恢复")
        }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        let engine = try SleepGuard(system: MacSystem(), store: store)
        try engine.recover(sessionVerified: ConsoleSession.verified)
    }
}
