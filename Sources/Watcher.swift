import AppKit
import CoreBluetooth
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

struct RuntimeStatus {
    var configuration: AppConfiguration
    var pending = false
    var snapshot: Snapshot?
    var power: PowerPreferencesSnapshot?
    var hasPowerBackup = false
    var corners: [HotCornerConfiguration] = []
    var blockers: [String] = []
    var helperReady = false
    var eventsReady = false
    var lastOrigin: SleepOrigin?
    var lastReason: TriggerDecisionReason?
    var lastTriggerAt: Date?
    var lastRecoveryAt: Date?
    var failure: String?
}

final class Acknowledgement {
    private let lock = NSLock()
    private var done = false
    private let port: io_connect_t
    private let argument: Int
    init(port: io_connect_t, argument: Int) { self.port = port; self.argument = argument }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true
        IOAllowPowerChange(port, argument)
    }
}

/// UI never reads mutable guard state. All transitions, settings and reports
/// are serialized here; only immutable status copies cross to the main thread.
final class Watcher: NSObject {
    let queue = DispatchQueue(label: "local.sleepseal.state")
    private let system: MacSystem
    private let engine: SleepGuard
    private let transitions: SleepTransitions
    private let configurationStore: AppConfigurationStore
    private let preferences: PowerPreferencesManager
    private let classifier = SleepOriginClassifier()
    private var configuration: AppConfiguration
    private var status: RuntimeStatus
    private let coordinator = ProtectionCoordinator()
    private var migrationFinalized = false
    private var powerPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var timer: DispatchSourceTimer?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private let lidObserver = LidObserver()
    private var screenLockedObserved = false
    private var lastReportSignature = ""
    private var lastReportAt = Date.distantPast
    var updated: ((RuntimeStatus) -> Void)?

    init(existingInstallation: Bool) throws {
        system = MacSystem()
        engine = try SleepGuard(system: system, store: JSONStore())
        transitions = SleepTransitions(engine: engine)
        configurationStore = AppConfigurationStore()
        configuration = try configurationStore.load(existingInstallation: existingInstallation)
        preferences = try PowerPreferencesManager(adapter: MacPowerPreferencesAdapter(), store: JSONPowerPreferencesStore())
        status = RuntimeStatus(configuration: configuration)
        super.init()
        screenLockedObserved = ConsoleSession.locked || (engine.pending?.sawLock == true && engine.pending?.restorationAuthorized != true)
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerPort = IORegisterForSystemPower(context, &notificationPort, { context, _, type, argument in
            guard let context else { return }
            Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().powerEvent(type, Int(bitPattern: argument))
        }, &notifier)
        if powerPort != 0, let notificationPort, let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            status.eventsReady = true
        } else { status.failure = "Sleep event registration failed / 睡眠监听注册失败" }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(locked), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(displaySlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displayWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        lidObserver.changed = { [weak self] closed, causesSleep in
            let time = ProcessInfo.processInfo.systemUptime
            self?.queue.async { self?.classifier.recordLidChange(closed: closed && causesSleep, at: time) }
        }
        lidObserver.start()
        observePointer() // Seed occupancy: a parked pointer is not an entry.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in self?.observePointer() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in self?.observePointer(); return event }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.engine.pending != nil && ConsoleSession.isConsoleOwner {
                self.perform {
                    // Polling can add missing initial lock evidence, but a
                    // lagging lock property must not revoke an observed unlock.
                    if ConsoleSession.locked && self.engine.pending?.sawLock == false { try self.engine.didLock() }
                    let hadPending = self.engine.pending != nil
                    try self.engine.reconcile(sessionVerified: ConsoleSession.verified)
                    if hadPending && self.engine.pending == nil { self.status.lastRecoveryAt = Date() }
                }
            }
            self.refresh()
        }
        timer.resume(); self.timer = timer
        queue.async {
            self.classifier.recordLidChange(closed: LidState.closed, at: -100)
            self.refresh()
            // A restart without saved unlock evidence never invents an unlock.
            if self.engine.pending != nil && ConsoleSession.isConsoleOwner { self.perform { try self.engine.reconcile(sessionVerified: ConsoleSession.verified) }; self.publish() }
        }
    }

    private func observePointer() {
        let point = NSEvent.mouseLocation
        let screens = NSScreen.screens.enumerated().map { i, screen in
            HotCornerScreen(id: String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? i), x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: screen.frame.height)
        }
        let modifiers = Int(NSEvent.modifierFlags.rawValue), now = ProcessInfo.processInfo.systemUptime
        let configurations = HotCorners.read()
        queue.async {
            self.classifier.corners.observe(point: HotCornerPoint(x: point.x, y: point.y), screens: screens, modifiers: modifiers, configurations: configurations, at: now)
        }
    }

    private func perform(seconds: TimeInterval = 15, _ action: () throws -> Void) {
        do { try OperationBudget.perform(seconds: seconds) { try action() }; status.failure = nil }
        catch { status.failure = String(describing: error); log("Operation failed: \(error)") }
    }
    private func publish() {
        status.configuration = configuration; status.pending = engine.pending != nil
        status.hasPowerBackup = !preferences.backups.isEmpty
        let copy = status
        DispatchQueue.main.async { self.updated?(copy) }
        let signature = "\(status.pending)|\(configuration.protectionEnabled)|\(status.failure ?? "")|\(String(describing: status.lastTriggerAt))|\(String(describing: status.lastRecoveryAt))"
        if signature != lastReportSignature || Date().timeIntervalSince(lastReportAt) >= 60 {
            lastReportSignature = signature; lastReportAt = Date()
            log("Guard pending=\(status.pending), enabled=\(configuration.protectionEnabled), error=\(status.failure ?? "none")")
            try? writeReport(runtimeReportPath(), success: status.failure == nil, stage: "runtime", message: status.failure ?? "Ready", snapshot: nil, pending: engine.pending)
        }
    }
    func requestRefresh() { queue.async { self.refresh() } }
    private func refresh() {
        do {
            let power = try preferences.read()
            let radios = system.readRadios()
            let values = power.values.filter { $0.key.isEnergyMode }.map { PowerValue(scope: $0.source.rawValue, key: $0.key.rawValue, value: $0.value) }
            status.snapshot = Snapshot(wifi: radios.wifi, bluetooth: radios.bluetooth, power: values)
            status.power = power
            status.corners = HotCorners.read()
            classifier.corners.updateConfigurations(status.corners)
            status.helperReady = (try? PrivilegedPowerTool.verifyAuthorization()) != nil
            if engine.pending == nil && status.helperReady {
                do { try PrivilegedPowerTool.releaseProtection() }
                catch { status.failure = String(describing: error) }
            }
            if status.eventsReady && status.helperReady && CBManager.authorization == .allowedAlways && engine.pending == nil && !migrationFinalized {
                do { try PrivilegedPowerTool.finalizeMigration(); migrationFinalized = true }
                catch { status.failure = String(describing: error); log("Migration cleanup: \(error)") }
            }
            let assertions = try command("/usr/bin/pmset", ["-g", "assertions"])
            status.blockers = SleepBlockers.parse(assertions.output)
        } catch { status.failure = String(describing: error); status.snapshot = nil; status.power = nil }
        publish()
    }

    private func sleep(_ source: SleepSource, at now: TimeInterval, idleSeconds: TimeInterval) {
        guard ConsoleSession.isConsoleOwner else { return }
        let displayMinutes: Int? = {
            guard let power = status.power else { return nil }
            // Use the current power source, not the shorter of two timers.
            let source = Self.currentPowerSource()
            return power.value(source: source, key: .displaySleep)?.value
        }()
        let origin = classifier.classify(source, at: now, lidIsClosed: LidState.closed,
            inputIdleSeconds: idleSeconds, displaySleepMinutes: displayMinutes)
        let ready = status.helperReady && status.eventsReady && CBManager.authorization == .allowedAlways
        let decision = coordinator.decide(origin: origin, policy: configuration.triggerPolicy,
            enabled: configuration.protectionEnabled, ready: ready, pending: engine.pending != nil)
        status.lastOrigin = decision.origin; status.lastReason = decision.policyDecision.reason; status.lastTriggerAt = Date()
        if decision.permissionsMissing { status.failure = "Protection needs Bluetooth and power-helper permission; connections kept / 保护需要蓝牙与电源工具权限，本次保持连接" }
        if decision.shouldAttemptProtection {
            // The acknowledgement deadline begins at notification receipt, not
            // after other work has drained from the serial queue.
            let remaining = source == .system ? min(15, max(0, 18 - (ProcessInfo.processInfo.systemUptime - now))) : 15
            if remaining > 0 {
                perform(seconds: remaining) { try transitions.sleep(source, sessionLocked: ConsoleSession.locked || screenLockedObserved) }
            } else { status.failure = "Sleep preparation deadline elapsed; saved recovery retained / 睡眠准备已超时，保留原恢复记录" }
        }
        publish() // No diagnostic hardware reads on the acknowledgement path.
    }
    private func wake(_ source: SleepSource) {
        coordinator.didWake(); classifier.didWake()
        if ConsoleSession.isConsoleOwner { perform { try transitions.wake(source, sessionVerified: ConsoleSession.verified) } }
        publish()
        queue.async { self.refresh() }
    }
    private func powerEvent(_ type: UInt32, _ argument: Int) {
        switch type {
        case 0xe0000270: // canSystemSleep is an idle proposal, not actual sleep.
            let time = ProcessInfo.processInfo.systemUptime
            queue.async { self.classifier.recordIdleSleepProposal(at: time) }
            IOAllowPowerChange(powerPort, argument)
        case 0xe0000290:
            queue.async { self.classifier.cancelIdleSleepProposal() }
        case 0xe0000280:
            let eventTime = ProcessInfo.processInfo.systemUptime
            let ack = Acknowledgement(port: powerPort, argument: argument)
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { ack.finish() }
            queue.async { defer { ack.finish() }; self.sleep(.system, at: eventTime, idleSeconds: 0) }
        case 0xe0000300:
            queue.async { self.wake(.system) }
        default: break
        }
    }
    @objc private func displaySlept(_ note: Notification) {
        let time = ProcessInfo.processInfo.systemUptime
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        queue.async { self.sleep(.display, at: time, idleSeconds: idle) }
    }
    @objc private func displayWoke(_ note: Notification) { queue.async { self.wake(.display) } }
    @objc private func locked(_ note: Notification) {
        queue.async { self.screenLockedObserved = true; self.perform { try self.engine.didLock() }; self.publish() }
    }
    @objc private func unlocked(_ note: Notification) {
        queue.async {
            self.screenLockedObserved = false
            guard let id = self.engine.pending?.id else { return }
            self.perform { try self.engine.observedUnlock(gateID: id, sessionVerified: ConsoleSession.verified) }
            if self.engine.pending == nil { self.status.lastRecoveryAt = Date() }
            self.publish()
            self.queue.async { self.refresh() }
            for delay in [0.2, 1.5, 4.0] {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    guard self.engine.pending?.id == id else { return }
                    self.perform { try self.engine.reconcile(sessionVerified: ConsoleSession.verified) }
                    if self.engine.pending == nil { self.status.lastRecoveryAt = Date(); self.queue.async { self.refresh() } }
                    self.publish()
                }
            }
        }
    }
    func resumeAfterFailedControl() {
        queue.async { self.coordinator.resumeAfterFailedControl(); self.publish() }
    }
    func changeConfiguration(_ update: @escaping (inout AppConfiguration) throws -> Void, completion: @escaping (String?) -> Void) {
        queue.async {
            do { var next = self.configuration; try update(&next); try self.configurationStore.save(next); self.configuration = next; self.coordinator.configurationDidChange(paused: next.protectionPaused); self.publish(); DispatchQueue.main.async { completion(nil) } }
            catch { DispatchQueue.main.async { completion(String(describing: error)) } }
        }
    }
    func requestSleep(completion: @escaping (String?) -> Void) {
        queue.async {
            let token = self.classifier.recordManualRequest(at: ProcessInfo.processInfo.systemUptime)
            let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            let result = port == 0 ? kIOReturnNotFound : IOPMSleepSystem(port)
            if port != 0 { IOServiceClose(port) }
            self.classifier.completeManualRequest(token, accepted: result == kIOReturnSuccess)
            DispatchQueue.main.async { completion(result == kIOReturnSuccess ? nil : "macOS rejected sleep request / macOS 拒绝睡眠请求 (\(result))") }
        }
    }
    func recover(freeze: Bool = false, completion: @escaping (String?) -> Void) {
        queue.async {
            var failure: String?
            do {
                try self.coordinator.recover(freeze: freeze) {
                    try OperationBudget.perform { try self.engine.recover(sessionVerified: ConsoleSession.verified) }
                }
                self.status.lastRecoveryAt = Date()
            } catch { failure = String(describing: error); self.status.failure = failure }
            self.refresh(); DispatchQueue.main.async { completion(failure) }
        }
    }
    func applyPower(_ edits: [PowerPreferenceEdit]?, restore: Bool, completion: @escaping (String?) -> Void) {
        queue.async {
            var failure: String?
            do {
                let result = try restore ? self.preferences.restoreOriginals(guardPending: self.engine.pending != nil)
                    : self.preferences.apply(edits ?? [], guardPending: self.engine.pending != nil)
                self.status.power = result.actual
                if !result.succeeded { failure = result.errors.joined(separator: "\n") }
            } catch { failure = String(describing: error) }
            self.refresh(); DispatchQueue.main.async { completion(failure) }
        }
    }
    static func currentPowerSource() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return .adapter }
        return source as String == "Battery Power" ? .battery : .adapter
    }
}
