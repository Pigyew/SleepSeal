import AppKit
import CoreBluetooth
import IOKit
import IOKit.pwr_mgt
import Darwin

// IOKit/IOMessage.h macros are not imported by Swift. These are their ABI values.
private let canSystemSleep: UInt32 = 0xe0000270
private let systemWillSleep: UInt32 = 0xe0000280
private let systemHasPoweredOn: UInt32 = 0xe0000300

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
    let queue = DispatchQueue(label: "local.sleepseal.state")
    private var powerPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var timer: DispatchSourceTimer?

    init(engine: SleepGuard) { self.engine = engine }

    func perform(_ name: String, _ action: () throws -> Void) {
        do { try action(); log(name) } catch { log("\(name)失败：\(error)") }
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
        // Fast user switching is deliberately not an unlock signal.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.engine.pending != nil else { return }
            if ConsoleSession.locked { self.perform("确认锁定") { try self.engine.didLock() } }
            self.perform("核对守护状态") { try self.engine.reconcile(sessionVerified: ConsoleSession.verified) }
        }
        timer.resume()
        self.timer = timer
        queue.async {
            if ConsoleSession.locked { self.perform("确认锁定") { try self.engine.didLock() } }
            // A restart never treats an already visible desktop as a new unlock.
            if self.engine.pending != nil {
                self.perform("恢复守护") { try self.engine.reconcile(sessionVerified: ConsoleSession.verified) }
            }
        }
        log("守护已启动；仅在屏幕解锁事件后恢复设置")
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
                self.perform("睡眠前处理") { try self.engine.beforeSleep() }
                if ConsoleSession.locked { self.perform("确认锁定") { try self.engine.didLock() } }
            }
        } else if type == systemHasPoweredOn {
            queue.async { self.perform("唤醒后保持关闭") { try self.engine.didWake() } }
        }
    }

    @objc private func locked(_ note: Notification) {
        queue.async { self.perform("收到锁屏事件") { try self.engine.didLock() } }
    }

    @objc private func unlocked(_ note: Notification) {
        // Session properties can trail the distributed notification briefly.
        queue.async {
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
    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = CBManager.authorization == .allowedAlways ? "蓝牙权限已就绪" : "需要允许蓝牙权限"
            alert.informativeText = CBManager.authorization == .allowedAlways
                ? "请返回安装窗口继续。此步骤没有关闭蓝牙或 Wi-Fi。"
                : "请在系统设置 → 隐私与安全性 → 蓝牙中允许 SleepSeal，然后重新安装。"
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }
}

@main struct Main {
    static func main() {
        guard getuid() != 0 else { fputs("请使用普通用户运行，不能以 root 运行。\n", stderr); exit(1) }
        let option = CommandLine.arguments.dropFirst().first ?? "--help"
        if option == "--check-permission" {
            guard CBManager.authorization == .allowedAlways else {
                fputs("尚未允许蓝牙权限；请在系统设置中允许 SleepSeal 后重新安装。\n", stderr)
                exit(1)
            }
            return
        }
        if option == "--preflight" {
            do {
                guard CBManager.authorization == .allowedAlways else { throw GuardFailure("蓝牙权限未允许") }
                let snapshot = try MacSystem().capture()
                for value in snapshot.power {
                    for target in Set([value.value, PowerPolicy.desired(value)]) {
                        let result = try command("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset",
                            value.scope, value.key, String(target)])
                        guard result.status == 0 else {
                            throw GuardFailure("电源权限未就绪：\(value.scope) \(value.key)；守护尚未启动")
                        }
                    }
                }
                print("安装前检查通过；未切换无线或电源设置。")
            } catch { log("安装前检查失败：\(error)"); exit(1) }
            return
        }
        if option == "--permissions" {
            NSApplication.shared.setActivationPolicy(.accessory)
            let request = PermissionRequest()
            withExtendedLifetime(request) { NSApplication.shared.run() }
            return
        }
        if option == "--doctor" {
            let system = MacSystem()
            print("SleepSeal 0.1 — 只读检查")
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
            try watcher.start()
            withExtendedLifetime(watcher) { RunLoop.main.run() }
        } catch { log("启动或恢复失败：\(error)"); exit(1) }
    }
}
