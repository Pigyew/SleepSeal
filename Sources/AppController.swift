import AppKit
import SwiftUI
import CoreBluetooth

@MainActor final class AppController: NSObject, CBCentralManagerDelegate {
    let model: DashboardModel
    private var watcher: Watcher?
    private var listener: AgentListener?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var bluetoothRequest: CBCentralManager?
    private var quitAuthorized = false
    private var onboardingPresented = false
    private let mock: Bool

    init(mock: Bool = false, language: UILanguage = .system, page: DashboardPage = .overview) {
        self.mock = mock
        model = mock ? DashboardModel.mock(language: language, page: page) : DashboardModel()
        super.init()
        if !mock { model.onAction = { [weak self] action in self?.handle(action) } }
    }
    func start(existingInstallation: Bool, show: Bool) {
        makeMenu()
        if !mock {
            do {
                let watcher = try Watcher(existingInstallation: existingInstallation)
                watcher.updated = { [weak self] status in self?.receive(status) }
                self.watcher = watcher
                watcher.start()
                listener = try AgentListener { [weak self] in self?.showDashboard() }
                listener?.start()
            } catch {
                model.serviceAvailable = false; model.statusKey = "guard.error"
                model.detailKey = "guard.error.detail"; feedback(String(describing: error))
            }
        }
        if show || mock { showDashboard() }
    }
    func showDashboard() {
        if window == nil {
            let content = NSHostingView(rootView: DashboardView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "SleepSeal"; window.contentView = content
            window.contentMinSize = NSSize(width: 800, height: 560)
            window.isReleasedWhenClosed = false
            window.center(); self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    private func makeMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "SleepSeal")
        }
        let menu = NSMenu()
        func item(_ key: String, _ selector: Selector, shortcut: String = "") {
            let item = NSMenuItem(title: model.text(key), action: selector, keyEquivalent: shortcut); item.target = self; menu.addItem(item)
        }
        item("menu.open", #selector(openPanel), shortcut: ",")
        menu.addItem(.separator())
        item("action.sleep", #selector(sleepNow)); item("action.displayOff", #selector(displayOff))
        item(model.isPaused ? "menu.resume" : "menu.pause", #selector(togglePause))
        item("action.restore", #selector(restore))
        menu.addItem(.separator()); item("menu.quit", #selector(quit), shortcut: "q")
        statusMenu = menu
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(statusPressed)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    @objc private func statusPressed() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem?.button {
            statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else { showDashboard() }
    }
    @objc private func openPanel() { showDashboard() }
    @objc private func sleepNow() { if mock { model.send(.sleepNow) } else { handle(.sleepNow) } }
    @objc private func displayOff() { if mock { model.send(.displayOff) } else { handle(.displayOff) } }
    @objc private func togglePause() { model.send(.setPaused(!model.isPaused)) }
    @objc private func restore() { model.send(.restoreProtection) }
    @objc private func quit() { NSApp.terminate(nil) }
    func requestQuit() {
        if mock || quitAuthorized { NSApp.reply(toApplicationShouldTerminate: true); NSApp.stop(nil); exit(0) }
        guard let watcher else { quitAuthorized = true; NSApp.terminate(nil); return }
        model.isBusy = true
        watcher.recover(freeze: true) { [weak self] error in
            guard let self else { return }; self.model.isBusy = false
            if let error { self.feedback(error); self.showDashboard(); NSApp.reply(toApplicationShouldTerminate: false) }
            else { self.quitAuthorized = true; NSApp.reply(toApplicationShouldTerminate: true); NSApp.terminate(nil) }
        }
    }
    var canTerminate: Bool { quitAuthorized || mock }
    private func feedback(_ error: String? = nil, success: String = "feedback.saved") {
        model.feedbackKey = error == nil ? success : "feedback.failed"
        model.feedbackDetail = error.map { RuntimeErrorPresentation.message($0, languageCode: model.language.localeIdentifier) } ?? ""; model.feedbackIsError = error != nil
    }
    private func complete(_ error: String?, success: String = "feedback.saved") {
        model.isBusy = false
        if error != nil { watcher?.resumeAfterFailedControl() }
        feedback(error, success: success)
    }
    private func receive(_ status: RuntimeStatus) {
        let c = status.configuration
        model.language = UILanguage(rawValue: c.language.rawValue) ?? .system
        model.onboardingRequired = !c.onboardingCompleted
        model.isEnabled = c.onboardingCompleted; model.isPaused = c.protectionPaused
        model.loginEnabled = c.launchAtLogin; model.guardPending = status.pending
        model.quitBlockingApps = c.quitBlockingApps
        model.serviceAvailable = status.eventsReady
        let ready = status.eventsReady && status.helperReady && CBManager.authorization == .allowedAlways
        model.statusKey = status.failure != nil ? "guard.error" : status.pending ? "guard.protecting" : !c.onboardingCompleted ? "guard.setup" : c.protectionPaused ? "guard.paused" : ready ? "guard.ready" : "guard.error"
        model.detailKey = model.statusKey + ".detail"
        let policy = UITriggerPolicy(allSources: c.triggerPolicy.mode == .all,
            sources: Set(c.triggerPolicy.sources.compactMap { UITrigger(rawValue: $0.rawValue) }),
            allConfiguredCorners: c.triggerPolicy.selectedCorners == nil,
            selectedCorners: Set((c.triggerPolicy.selectedCorners ?? Set(HotCorner.allCases)).map(\.rawValue)))
        if !model.policyDirty { model.policy = policy }
        model.savedPolicy = policy
        if let snapshot = status.snapshot {
            model.wifi = snapshot.wifi.isEmpty ? .unknown : snapshot.wifi.values.contains(true) ? .on : .off
            model.bluetooth = snapshot.bluetooth.map { $0 ? .on : .off } ?? .unknown
            let source = Watcher.currentPowerSource().rawValue
            model.lowPower = snapshot.power.first { $0.scope == source }.map { $0.value == 1 ? .on : .off } ?? .unknown
        }
        else { model.wifi = .unknown; model.bluetooth = .unknown; model.lowPower = .unknown }
        if let origin = status.lastOrigin {
            switch origin {
            case .manual: model.lastTriggerKey = "trigger.manual"
            case .lid: model.lastTriggerKey = "trigger.lid"
            case .hotCorner: model.lastTriggerKey = "trigger.hotCorner"
            case .idle: model.lastTriggerKey = "trigger.idle"
            case .unknown: model.lastTriggerKey = "trigger.unknown"
            }
            let skipped = [.unknownSource, .unselectedSource, .unselectedCorner].contains(status.lastReason)
            model.lastTriggerDetail = [status.lastTriggerAt.map(time) ?? "", skipped ? model.text("event.skipped") : "", origin.isAutomaticallyIdentified ? model.text("trigger.automatic") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let date = status.lastRecoveryAt { model.lastRecoveryKey = "feedback.restored"; model.lastRecoveryDetail = time(date) }
        model.corners = status.corners.map { UICorner(id: $0.corner.rawValue, action: $0.action, modifierSymbols: Self.modifierSymbols($0.modifier)) }
        if let power = status.power {
            var profiles: [UIPowerScope: UIPowerProfile] = [:]
            for source in PowerSource.allCases {
                let scope: UIPowerScope = source == .battery ? .battery : .adapter
                profiles[scope] = UIPowerProfile(values: Dictionary(uniqueKeysWithValues: power.values.filter { $0.source == source }.map { ($0.key.rawValue, $0.value) }), supportedModes: power.supportedEnergyModes[source] ?? [], modeKey: power.energyMode(source: source)?.key.rawValue, available: power.values.contains { $0.source == source })
            }
            if model.powerDrafts.isEmpty { model.powerProfiles = profiles; model.powerConflict = false }
            else {
                // Only an edited field participates in its compare-and-swap.
                // Unrelated external changes and transient energy-mode changes
                // must not block a pending display/sleep timer edit.
                for scope in UIPowerScope.allCases {
                    for (key, original) in model.powerProfiles[scope]?.values ?? [:] {
                        if model.powerDrafts[model.draftID(scope, key)] != nil {
                            if profiles[scope]?.values[key] != original { model.powerConflict = true }
                            profiles[scope]?.values[key] = original
                        }
                    }
                }
                model.powerProfiles = profiles
            }
            model.powerLoaded = true
        }
        model.powerLoaded = status.power != nil
        model.hasPowerBackup = status.hasPowerBackup
        model.permissions = [
            UIPermission(id: "bluetooth", titleKey: "permission.bluetooth", detailKey: CBManager.authorization == .allowedAlways ? "permission.ready" : "permission.missing", ready: CBManager.authorization == .allowedAlways, action: .openBluetoothSettings),
            UIPermission(id: "helper", titleKey: "permission.helper", detailKey: status.helperReady ? "permission.ready" : "permission.missing", ready: status.helperReady, action: .repairInstallation),
            UIPermission(id: "events", titleKey: "permission.events", detailKey: status.eventsReady ? "permission.ready" : "permission.missing", ready: status.eventsReady, action: .repairInstallation)
        ]
        model.sleepBlockers = status.blockers; model.blockersLoaded = true
        if let result = status.blockerCleanup {
            var lines = [String(format: model.text("blockers.result"), result.requestedCount, result.terminatedCount, result.remainingCount)]
            if result.cancelled { lines.append(model.text("blockers.cancelled")) }
            if result.timedOut { lines.append(model.text("blockers.timedOut")) }
            if let error = result.error { lines.append(RuntimeErrorPresentation.message(error, languageCode: model.language.localeIdentifier)) }
            model.blockerCleanupDetail = lines.joined(separator: " · ")
        } else { model.blockerCleanupDetail = "" }
        if let error = status.failure { feedback(error) }
        if model.onboardingRequired && !onboardingPresented { onboardingPresented = true; showDashboard() }
        makeMenu()
    }
    private func time(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: model.language.localeIdentifier); f.dateStyle = .short; f.timeStyle = .short; return f.string(from: date) }
    private static func modifierSymbols(_ raw: Int) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(max(raw, 0)))
        return [(NSEvent.ModifierFlags.control,"⌃"),(.option,"⌥"),(.shift,"⇧"),(.command,"⌘")].filter { flags.contains($0.0) }.map { $0.1 }.joined()
    }
    private func handle(_ action: DashboardAction) {
        // Turning off the opt-in must invalidate pending main-thread requests
        // even while the serial coordinator is waiting for an app to quit.
        let disablingQuitRequests: Bool
        if case .setQuitBlockingApps(false) = action {
            disablingQuitRequests = true; watcher?.cancelBlockingAppRequests()
        } else { disablingQuitRequests = false }
        if model.isBusy && !disablingQuitRequests { return }
        if watcher == nil {
            switch action {
            case .repairInstallation, .openHotCorners, .openBluetoothSettings, .exportDiagnostics, .setLanguage: break
            default: feedback("Background service unavailable. Reopen the installed app. / 后台服务不可用，请重新打开已安装应用。"); return
            }
        }
        switch action {
        case .refresh:
            if model.powerConflict {
                let alert = NSAlert(); alert.messageText = model.text("power.conflict")
                alert.informativeText = model.text("power.refresh.confirm")
                alert.addButton(withTitle: model.text("action.refresh")); alert.addButton(withTitle: model.text("action.cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                model.powerDrafts.removeAll()
            }
            watcher?.requestRefresh()
        case .enableProtection:
            model.isBusy = true
            bluetoothRequest = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            watcher?.changeConfiguration({ $0.onboardingCompleted = true; $0.protectionPaused = false }) { [weak self] error in self?.complete(error) }
        case .savePolicy(let policy):
            model.isBusy = true
            watcher?.changeConfiguration({ config in config.triggerPolicy = TriggerPolicy(mode: policy.allSources ? .all : .custom, sources: Set(policy.sources.compactMap { ProtectionTrigger(rawValue: $0.rawValue) }), selectedCorners: policy.allConfiguredCorners ? nil : Set(policy.selectedCorners.compactMap(HotCorner.init(rawValue:)))) }) { [weak self] error in self?.complete(error) }
        case .setLanguage(let language):
            model.language = language; makeMenu()
            watcher?.changeConfiguration({ $0.language = AppLanguage(rawValue: language.rawValue) ?? .system }) { [weak self] error in self?.complete(error) }
        case .setLogin(let enabled):
            model.isBusy = true
            watcher?.changeConfiguration({ config in try UserAgentInstallation.updateLogin(enabled); config.launchAtLogin = enabled }) { [weak self] error in self?.complete(error) }
        case .setQuitBlockingApps(let enabled):
            if !enabled { watcher?.cancelBlockingAppRequests() }
            model.isBusy = true
            watcher?.changeConfiguration({ $0.quitBlockingApps = enabled }) { [weak self] error in self?.complete(error) }
        case .setPaused(let paused):
            guard let watcher else { return }; model.isBusy = true
            let save = { [weak self] in watcher.changeConfiguration({ $0.protectionPaused = paused }) { error in self?.complete(error) } }
            if paused { watcher.recover(freeze: true) { [weak self] error in if let error { self?.complete(error) } else { save() } } }
            else { save() }
        case .restoreProtection:
            model.isBusy = true; watcher?.recover { [weak self] error in self?.complete(error, success: "feedback.restored") }
        case .sleepNow:
            guard model.isEnabled, let watcher else { showDashboard(); return }
            model.isBusy = true; watcher.requestSleep { [weak self] error in self?.complete(error, success: "feedback.sleepRequested") }
        case .displayOff:
            model.isBusy = true
            DispatchQueue.global().async {
                let result = try? command("/usr/bin/pmset", ["displaysleepnow"])
                DispatchQueue.main.async { self.complete(result?.status == 0 ? nil : "Display sleep request failed / 关屏请求失败", success: "feedback.sleepRequested") }
            }
        case .openHotCorners:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
        case .openBluetoothSettings:
            bluetoothRequest = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
        case .repairInstallation:
            NSWorkspace.shared.open(URL(string: "https://github.com/Pigyew/SleepSeal/releases/tag/v0.2.1")!)
        case .applyPower(let edits):
            let values = edits.compactMap { edit -> PowerPreferenceEdit? in
                guard let source = PowerSource(rawValue: edit.scope.commandFlag), let key = PowerSettingKey(rawValue: edit.key) else { return nil }
                return PowerPreferenceEdit(original: PowerPreferenceValue(source: source, key: key, value: edit.original), target: edit.value)
            }
            guard values.count == edits.count else { feedback("Invalid edit / 无效更改"); return }
            model.isBusy = true
            watcher?.applyPower(values, restore: false) { [weak self] error in
                guard let self else { return }
                if error == nil { self.model.powerDrafts.removeAll(); self.model.powerConflict = false; self.watcher?.requestRefresh() }
                else { self.model.powerConflict = true }
                self.complete(error)
            }
        case .restorePower:
            model.isBusy = true; watcher?.applyPower(nil, restore: true) { [weak self] error in self?.complete(error, success: "feedback.restored") }
        case .exportDiagnostics: exportDiagnostics()
        case .uninstall(let restorePower): uninstall(restorePower: restorePower)
        }
    }
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) { Task { @MainActor in watcher?.requestRefresh() } }
    private func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SleepSeal-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Deliberately exclude raw logs, interface names, app blockers, user paths,
        // network identifiers, pending snapshots and any account information.
        let report: [String: Any] = ["version": model.appVersion, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "guardPending": model.guardPending, "status": model.statusKey, "wifi": model.wifi.key,
            "bluetooth": model.bluetooth.key, "lowPower": model.lowPower.key,
            "permissions": model.permissions.map { ["id": $0.id, "ready": $0.ready] as [String: Any] }]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic); feedback(nil, success: "feedback.exported") }
        catch { feedback(String(describing: error)) }
    }
    private func uninstall(restorePower: Bool) {
        guard let watcher else { feedback("Restore the recovery record before uninstalling / 请先恢复记录再卸载"); return }
        model.isBusy = true
        watcher.recover(freeze: true) { [weak self] error in
            guard let self else { return }
            if let error { self.complete(error); return }
            let remove = {
                DispatchQueue.global().async {
                    do {
                        try PrivilegedPowerTool.verifyInstallation()
                        let result = try command("/usr/bin/sudo", ["-n", PrivilegedPowerTool.path, "uninstall"], timeout: 10)
                        guard result.status == 0 else { throw GuardFailure(result.output) }
                        try UserAgentInstallation.removeOwnAgentFile()
                        // Explicitly unregister the loaded Mach service too;
                        // another account may still use the shared application.
                        let stopped = try command("/bin/launchctl", ["bootout", "\(UserAgentInstallation.domain)/\(AgentIdentity.label)"], timeout: 5)
                        guard stopped.status == 0 else { throw GuardFailure("Startup service cleanup needs retry / 启动服务清理需要重试") }
                        DispatchQueue.main.async { self.quitAuthorized = true; NSApp.terminate(nil) }
                    } catch { DispatchQueue.main.async { self.complete(String(describing: error)) } }
                }
            }
            if restorePower { watcher.applyPower(nil, restore: true) { error in if let error { self.complete(error) } else { remove() } } }
            else { remove() }
        }
    }
    func capture(to directory: URL, appearance: String) throws {
        guard mock else { throw GuardFailure("Screenshots require mock mode") }
        showDashboard()
        window?.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw GuardFailure("Cannot capture window") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(model.language.rawValue)-\(model.page.rawValue)-\(appearance).png"
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent(name)) }
    }
}
