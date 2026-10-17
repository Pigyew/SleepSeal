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
    var blockerCleanup: BlockingAppsResult?
    var helperReady = false
    var eventsReady = false
    var settingsReady = true
    var powerPreferencesReady = true
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
    private let preferences: PowerPreferencesManager?
    private let powerAdapter: MacPowerPreferencesAdapter
    private let settings: RuntimeSettings
    private var failures = RuntimeFailures()
    private let classifier = SleepOriginClassifier()
    private var configuration: AppConfiguration
    private var status: RuntimeStatus
    private let coordinator = ProtectionCoordinator()
    private let blockingCoordinator = BlockingAppsCoordinator()
    private let blockingCancellation = BlockingAppsCancellation()
    private var migrationFinalized = false
    private var powerPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var timer: DispatchSourceTimer?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private let lidObserver = LidObserver()
    private var screenLockedObserved = false
    private let unlockFence = UnlockEventFence()
    private var pointerFilter = HotCornerPointerFilter() // Main-thread only.
    private var dashboardVisible = false // State queue only.
    private var timerInterval: TimeInterval = 0
    private var lastHelperCheck: TimeInterval = -.infinity
    private var ownershipReleaseRequired = true
    private var shuttingDown = false
    private var lastReportSignature = ""
    private var lastReportAt = Date.distantPast
    var updated: ((RuntimeStatus) -> Void)?

    init(existingInstallation: Bool) throws {
        system = MacSystem()
        engine = try SleepGuard(system: system, store: JSONStore())
        transitions = SleepTransitions(engine: engine)
        configurationStore = AppConfigurationStore()
        powerAdapter = MacPowerPreferencesAdapter()
        let store = configurationStore, adapter = powerAdapter
        settings = RuntimeSettings.load(configuration: { try store.load(existingInstallation: existingInstallation) },
            preferences: { try PowerPreferencesManager(adapter: adapter, store: JSONPowerPreferencesStore()) })
        configuration = settings.configuration
        preferences = settings.preferences
        failures.startup = settings.issue
        status = RuntimeStatus(configuration: configuration)
        status.settingsReady = settings.ready
        status.powerPreferencesReady = settings.ready && preferences != nil
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
        } else { failures.registration = "Sleep event registration failed / 睡眠监听注册失败" }
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
        self.timer = timer
        scheduleTimer()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.engine.pending != nil && ConsoleSession.isConsoleOwner {
                self.perform(clearOnSuccess: self.engine.pending?.restorationAuthorized != true) {
                    // Polling can add missing initial lock evidence, but a
                    // lagging lock property must not revoke an observed unlock.
                    if ConsoleSession.locked && self.engine.pending?.sawLock == false { try self.engine.didLock() }
                    let hadPending = self.engine.pending != nil
                    try self.engine.reconcile(sessionVerified: ConsoleSession.verified)
                    if hadPending && self.engine.pending == nil { self.status.lastRecoveryAt = Date() }
                }
            }
            self.refresh(force: false)
            // A blocking assertion can prevent the actual idle-sleep event.
            // Inspect only after a fresh read of the relevant system timers.
            if self.engine.pending == nil && !self.coordinator.isQuiescing && self.status.helperReady
                && self.status.eventsReady && self.settings.ready && CBManager.authorization == .allowedAlways {
                _ = self.prepareBlockingApps(origin: .idle, requiresIdleThreshold: true, budget: 2)
                self.publish()
            }
        }
        timer.resume()
        queue.async {
            self.classifier.recordLidChange(closed: LidState.closed, at: -100)
            self.refresh()
            // A restart without saved unlock evidence never invents an unlock.
            if self.engine.pending != nil && ConsoleSession.isConsoleOwner { self.perform(clearOnSuccess: self.engine.pending?.restorationAuthorized != true) { try self.engine.reconcile(sessionVerified: ConsoleSession.verified) }; self.publish() }
        }
    }

    private func observePointer() {
        let point = NSEvent.mouseLocation
        let screens = NSScreen.screens.enumerated().map { i, screen in
            HotCornerScreen(id: String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? i), x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: screen.frame.height)
        }
        let modifiers = Int(NSEvent.modifierFlags.rawValue), now = ProcessInfo.processInfo.systemUptime
        let location = HotCornerPoint(x: point.x, y: point.y)
        guard pointerFilter.shouldSubmit(point: location, screens: screens) else { return }
        let configurations = HotCorners.read()
        queue.async {
            self.classifier.corners.observe(point: location, screens: screens, modifiers: modifiers, configurations: configurations, at: now)
        }
    }

    private func scheduleTimer() {
        guard !shuttingDown else { return }
        let interval = RuntimeRefreshCadence.interval(pending: engine.pending != nil, dashboardVisible: dashboardVisible)
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
    }
    func setDashboardVisible(_ visible: Bool) {
        queue.async {
            self.dashboardVisible = visible; self.scheduleTimer()
            if visible { self.refresh() }
        }
    }

    private func perform(seconds: TimeInterval = 15, clearOnSuccess: Bool = true, _ action: () throws -> Void) {
        let hadPending = engine.pending != nil
        defer { if hadPending && engine.pending == nil { ownershipReleaseRequired = true } }
        do {
            try OperationBudget.perform(seconds: seconds) { try action() }
            if clearOnSuccess || (hadPending && engine.pending == nil) { failures.operation = nil }
            if hadPending && engine.pending == nil { status.lastRecoveryAt = Date() }
        }
        catch { failures.operation = String(describing: error); log("Operation failed: \(error)") }
    }
    private func publish() {
        status.configuration = configuration; status.pending = engine.pending != nil
        status.hasPowerBackup = !(preferences?.backups.isEmpty ?? true)
        status.failure = failures.message
        scheduleTimer()
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
    private func refresh(force: Bool = true) {
        guard !shuttingDown else { publish(); return }
        var diagnosticErrors: [String] = []
        do {
            let power = try powerAdapter.read()
            let radios = system.readRadios()
            let values = power.values.filter { $0.key.isEnergyMode }.map { PowerValue(scope: $0.source.rawValue, key: $0.key.rawValue, value: $0.value) }
            status.snapshot = Snapshot(wifi: radios.wifi, bluetooth: radios.bluetooth, power: values)
            status.power = power
            status.corners = HotCorners.read()
            classifier.corners.updateConfigurations(status.corners)
            let now = ProcessInfo.processInfo.systemUptime
            if force || now - lastHelperCheck >= 300 {
                status.helperReady = (try? PrivilegedPowerTool.verifyAuthorization()) != nil
                lastHelperCheck = now
            }
            if engine.pending == nil && status.helperReady && ownershipReleaseRequired {
                do { try PrivilegedPowerTool.releaseProtection(); ownershipReleaseRequired = false }
                catch { diagnosticErrors.append(String(describing: error)) }
            }
            if status.eventsReady && status.helperReady && CBManager.authorization == .allowedAlways && engine.pending == nil && !migrationFinalized {
                do { try PrivilegedPowerTool.finalizeMigration(); migrationFinalized = true }
                catch { diagnosticErrors.append(String(describing: error)); log("Migration cleanup: \(error)") }
            }
            let assertions = try command("/usr/bin/pmset", ["-g", "assertions"])
            guard assertions.status == 0 else { throw GuardFailure("Cannot read sleep blockers / 无法读取睡眠阻止项") }
            status.blockers = SleepBlockers.parse(assertions.output)
        } catch { diagnosticErrors.append(String(describing: error)); status.snapshot = nil; status.power = nil }
        failures.diagnostic = diagnosticErrors.isEmpty ? nil : diagnosticErrors.joined(separator: "\n")
        publish()
    }

    private func sleep(_ source: SleepSource, at now: TimeInterval, idleSeconds: TimeInterval) {
        guard ConsoleSession.isConsoleOwner else { return }
        // Revalidate cached corner evidence at the actual sleep boundary.
        status.corners = HotCorners.read()
        classifier.corners.updateConfigurations(status.corners)
        let displayMinutes: Int? = {
            guard let power = status.power else { return nil }
            // Use the current power source, not the shorter of two timers.
            let source = Self.currentPowerSource()
            return power.value(source: source, key: .displaySleep)?.value
        }()
        let origin = classifier.classify(source, at: now, lidIsClosed: LidState.closed,
            inputIdleSeconds: idleSeconds, displaySleepMinutes: displayMinutes)
        let ready = status.helperReady && status.eventsReady && settings.ready && CBManager.authorization == .allowedAlways
        let decision = coordinator.decide(origin: origin, policy: configuration.triggerPolicy,
            enabled: configuration.protectionEnabled, ready: ready, pending: engine.pending != nil)
        status.lastOrigin = decision.origin; status.lastReason = decision.policyDecision.reason; status.lastTriggerAt = Date()
        if decision.permissionsMissing && settings.ready { failures.diagnostic = "Protection needs Bluetooth and power-helper permission; connections kept / 保护需要蓝牙与电源工具权限，本次保持连接" }
        if decision.shouldAttemptProtection {
            // This is already a confirmed sleep event. Normal application quit
            // requests are best effort and share the acknowledgement deadline.
            let available = source == .system ? max(0, 18 - (ProcessInfo.processInfo.systemUptime - now)) : 15
            if decision.requested && available > 1 {
                _ = prepareBlockingApps(origin: decision.origin, requiresIdleThreshold: false,
                    selected: decision.policyDecision.shouldProtect, budget: min(2, available - 1))
            }
            // The acknowledgement deadline begins at notification receipt, not
            // after other work has drained from the serial queue.
            let remaining = source == .system ? min(15, max(0, 18 - (ProcessInfo.processInfo.systemUptime - now))) : 15
            if remaining > 0 {
                perform(seconds: remaining) { try transitions.sleep(source, sessionLocked: ConsoleSession.locked || screenLockedObserved) }
            } else { failures.operation = "Sleep preparation deadline elapsed; saved recovery retained / 睡眠准备已超时，保留原恢复记录" }
        }
        publish() // No diagnostic hardware reads on the acknowledgement path.
    }
    private func wake(_ source: SleepSource) {
        // A background/display wake must not repeatedly re-open save prompts.
        // New user input, verified unlock or a new explicit request resets the
        // attempt ledger; every wake still cancels work already in flight.
        blockingCoordinator.cancelActiveBatch()
        coordinator.didWake(); classifier.didWake()
        if ConsoleSession.isConsoleOwner { perform(clearOnSuccess: engine.pending?.restorationAuthorized != true) { try transitions.wake(source, sessionVerified: ConsoleSession.verified) } }
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
            unlockFence.invalidate()
            let eventTime = ProcessInfo.processInfo.systemUptime
            let idle = Self.inputIdleSeconds()
            let ack = Acknowledgement(port: powerPort, argument: argument)
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { ack.finish() }
            queue.async { defer { ack.finish() }; self.sleep(.system, at: eventTime, idleSeconds: idle) }
        case 0xe0000300:
            cancelBlockingAppRequests()
            queue.async { self.wake(.system) }
        default: break
        }
    }
    @objc private func displaySlept(_ note: Notification) {
        unlockFence.invalidate()
        let time = ProcessInfo.processInfo.systemUptime
        let idle = Self.inputIdleSeconds()
        queue.async { self.sleep(.display, at: time, idleSeconds: idle) }
    }
    @objc private func displayWoke(_ note: Notification) {
        cancelBlockingAppRequests()
        queue.async { self.wake(.display) }
    }
    @objc private func locked(_ note: Notification) {
        unlockFence.invalidate()
        queue.async { self.screenLockedObserved = true; self.perform(clearOnSuccess: false) { try self.engine.didLock() }; self.publish() }
    }
    @objc private func unlocked(_ note: Notification) {
        cancelBlockingAppRequests()
        let epoch = unlockFence.capture()
        queue.async {
            guard self.unlockFence.accepts(epoch) else { return }
            self.screenLockedObserved = false
            if ConsoleSession.verified { self.blockingCoordinator.reset(reason: .wake) }
            guard let id = self.engine.pending?.id else { return }
            self.perform(clearOnSuccess: false) { try self.engine.observedUnlock(gateID: id, sessionVerified: ConsoleSession.verified) }
            if self.engine.pending == nil { self.status.lastRecoveryAt = Date(); self.failures.operation = nil }
            self.publish()
            self.queue.async { self.refresh() }
            for delay in [0.2, 1.5, 4.0] {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    guard self.unlockFence.accepts(epoch), self.engine.pending?.id == id else { return }
                    self.perform(clearOnSuccess: self.engine.pending?.restorationAuthorized != true) { try self.engine.reconcile(sessionVerified: ConsoleSession.verified) }
                    if self.engine.pending == nil { self.status.lastRecoveryAt = Date(); self.queue.async { self.refresh() } }
                    self.publish()
                }
            }
        }
    }
    func resumeAfterFailedControl() {
        queue.async { guard !self.shuttingDown else { return }; self.coordinator.resumeAfterFailedControl(); self.publish() }
    }
    func prepareForUninstallCleanup() {
        cancelBlockingAppRequests()
        queue.async {
            self.shuttingDown = true
            self.coordinator.recover(freeze: true) {}
            self.timer?.cancel(); self.timer = nil
            self.status.settingsReady = false; self.status.powerPreferencesReady = false
            self.configuration.protectionPaused = true
            self.publish()
        }
    }
    func changeConfiguration(_ update: @escaping (inout AppConfiguration) throws -> Void, completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                guard self.settings.ready, !self.shuttingDown else { throw GuardFailure(self.settings.issue ?? "Saved settings need repair / 保存的设置需要修复") }
                var next = self.configuration; try update(&next); try self.configurationStore.save(next)
                self.configuration = next; self.coordinator.configurationDidChange(paused: next.protectionPaused)
                if !next.protectionEnabled || !next.quitBlockingApps {
                    self.cancelBlockingAppRequests()
                    self.blockingCoordinator.reset(reason: next.protectionPaused ? .protectionPaused : .configurationDisabled)
                }
                self.publish(); DispatchQueue.main.async { completion(nil) }
            }
            catch { DispatchQueue.main.async { completion(String(describing: error)) } }
        }
    }
    func requestSleep(completion: @escaping (String?) -> Void) {
        cancelBlockingAppRequests()
        let tokenAtRequest = blockingCancellation.token()
        queue.async {
            guard self.settings.ready, !self.coordinator.isQuiescing else {
                DispatchQueue.main.async { completion(self.settings.issue ?? "Protection is paused for another operation / 保护正在等待另一项操作完成") }; return
            }
            self.blockingCoordinator.reset(reason: .explicitSleep)
            var preparation: BlockingAppsResult?
            if self.configuration.protectionEnabled && self.configuration.quitBlockingApps
                && self.configuration.triggerPolicy.decision(for: .manual).shouldProtect {
                let result = BlockingApps.prepareForManualSleep(deadline: ProcessInfo.processInfo.systemUptime + 8,
                    cancelled: { self.blockingCancellation.isCancelled(tokenAtRequest) || !ConsoleSession.isConsoleOwner })
                preparation = result; self.status.blockerCleanup = result
            }
            if let result = preparation, !result.canProceedWithSleep {
                self.publish()
                DispatchQueue.main.async { completion("Some apps have not quit. Handle their save prompts or cancel, then retry sleep. / 部分应用尚未退出，请处理保存提示或取消后再重试睡眠。") }
                return
            }
            guard !self.blockingCancellation.isCancelled(tokenAtRequest), ConsoleSession.isConsoleOwner else {
                DispatchQueue.main.async { completion("Sleep preparation cancelled / 睡眠准备已取消") }; return
            }
            self.publish()
            let token = self.classifier.recordManualRequest(at: ProcessInfo.processInfo.systemUptime)
            let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            let result = port == 0 ? kIOReturnNotFound : IOPMSleepSystem(port)
            if port != 0 { IOServiceClose(port) }
            self.classifier.completeManualRequest(token, accepted: result == kIOReturnSuccess)
            DispatchQueue.main.async { completion(result == kIOReturnSuccess ? nil : "macOS rejected sleep request / macOS 拒绝睡眠请求 (\(result))") }
        }
    }
    func recover(freeze: Bool = false, completion: @escaping (String?) -> Void) {
        cancelBlockingAppRequests()
        queue.async {
            self.blockingCoordinator.reset(reason: .protectionPaused)
            var failure: String?
            let hadPending = self.engine.pending != nil
            do {
                try self.coordinator.recover(freeze: freeze) {
                    try OperationBudget.perform { try self.engine.recover(sessionVerified: ConsoleSession.verified) }
                }
                self.status.lastRecoveryAt = Date()
                self.failures.operation = nil
                if hadPending && self.engine.pending == nil { self.ownershipReleaseRequired = true }
            } catch { failure = String(describing: error); self.failures.operation = failure }
            self.refresh(); DispatchQueue.main.async { completion(failure) }
        }
    }
    /// Invalidate queued main-thread quit work immediately, before the serial
    /// coordinator can drain an in-progress preparation operation.
    func cancelBlockingAppRequests() { blockingCancellation.cancel() }

    private static func inputIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }

    private func prepareBlockingApps(origin: SleepOrigin, requiresIdleThreshold: Bool,
        selected: Bool? = nil, budget: TimeInterval, cancellationToken: UInt64? = nil) -> BlockingAppsResult? {
        guard settings.ready, configuration.protectionEnabled, configuration.quitBlockingApps,
              !coordinator.isQuiescing, ConsoleSession.isConsoleOwner,
              selected ?? configuration.triggerPolicy.decision(for: origin).shouldProtect else { return nil }
        let token = cancellationToken ?? blockingCancellation.token()
        let began = ProcessInfo.processInfo.systemUptime
        let idle = Self.inputIdleSeconds(), inputAt = began - idle
        let cancelled: () -> Bool = { [blockingCancellation] in
            if blockingCancellation.isCancelled(token) || !ConsoleSession.isConsoleOwner { return true }
            if requiresIdleThreshold {
                let currentIdle = Self.inputIdleSeconds()
                return !currentIdle.isFinite || ProcessInfo.processInfo.systemUptime - currentIdle > inputAt + 0.5
            }
            return false
        }
        guard !cancelled() else {
            let result = BlockingAppsResult(cancelled: true); status.blockerCleanup = result; return result
        }
        do {
            let inventory = try BlockingApps.inventory(deadline: began + budget, cancelled: cancelled)
            if cancelled() {
                let result = BlockingAppsResult(cancelled: true); status.blockerCleanup = result; return result
            }
            let remaining = began + budget - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                let result = BlockingAppsResult(timedOut: true); status.blockerCleanup = result; return result
            }
            let source = Self.currentPowerSource()
            guard let batch = blockingCoordinator.begin(configuration: configuration,
                isConsoleOwner: ConsoleSession.isConsoleOwner, inputIdleSeconds: Self.inputIdleSeconds(),
                systemSleepMinutes: status.power?.value(source: source, key: .systemSleep)?.value,
                displaySleepMinutes: status.power?.value(source: source, key: .displaySleep)?.value,
                assertions: inventory.assertions, applications: inventory.applications,
                currentUID: getuid(), ownPID: getpid(), at: ProcessInfo.processInfo.systemUptime,
                budget: remaining, origin: origin, requiresIdleThreshold: requiresIdleThreshold,
                protectionSelected: selected) else { return nil }
            let result = BlockingApps.requestQuitBlockingApps(applications: batch.applications,
                deadline: batch.deadline, cancelled: cancelled, shouldRequest: { current in
                    self.blockingCoordinator.claim(current, in: batch, current: current, at: ProcessInfo.processInfo.systemUptime)
                })
            blockingCoordinator.cancelActiveBatch()
            status.blockerCleanup = result
            log("Blocking apps requested=\(result.requestedCount), quit=\(result.terminatedCount), remaining=\(result.remainingCount), cancelled=\(result.cancelled), timedOut=\(result.timedOut)")
            return result
        } catch {
            let result = BlockingAppsResult(error: String(describing: error))
            status.blockerCleanup = result
            return result
        }
    }
    func applyPower(_ edits: [PowerPreferenceEdit]?, restore: Bool, completion: @escaping (String?) -> Void) {
        queue.async {
            var failure: String?
            do {
                guard self.settings.ready, !self.shuttingDown, let preferences = self.preferences else {
                    throw GuardFailure(self.settings.issue ?? "Saved power settings need repair / 电源备份需要修复")
                }
                let result = try restore ? preferences.restoreOriginals(guardPending: self.engine.pending != nil)
                    : preferences.apply(edits ?? [], guardPending: self.engine.pending != nil)
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
