import AppKit
import CoreWLAN
import IOBluetooth
import CoreGraphics
import CoreBluetooth
import Darwin

struct GuardFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Logs contain events and errors, never network names or addresses.
final class EventLog {
    static let shared = EventLog()
    private let lock = NSLock()
    private var previous: String?
    private var lastWrite = Date.distantPast
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SleepSeal", isDirectory: true)
    func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if previous == message && now.timeIntervalSince(lastWrite) < 60 { return }
        previous = message; lastWrite = now
        let data = Data("\(ISO8601DateFormatter().string(from: now)) \(String(message.prefix(16_384)))\n".utf8)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("events.log")
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > 1_048_576 {
                let oldest = directory.appendingPathComponent("events.2.log")
                if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
                let previous = directory.appendingPathComponent("events.1.log")
                if fm.fileExists(atPath: previous.path) { try fm.moveItem(at: previous, to: oldest) }
                if fm.fileExists(atPath: url.path) { try fm.moveItem(at: url, to: previous) }
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        } catch {
            // A logging failure must never prevent sleep or restoration.
        }
    }
}
func log(_ message: String) { EventLog.shared.write(message) }

struct CommandResult { let status: Int32; let output: String }

/// One monotonic deadline is shared by every child process in a transition.
final class OperationBudget {
    let deadline: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    init(seconds: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + seconds }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var remaining: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return cancelled ? 0 : max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }
    static var current: OperationBudget? { Thread.current.threadDictionary["SleepSeal.operationBudget"] as? OperationBudget }
    static func perform<T>(seconds: TimeInterval = 15, _ action: () throws -> T) rethrows -> T {
        let old = current
        Thread.current.threadDictionary["SleepSeal.operationBudget"] = old ?? OperationBudget(seconds: seconds)
        defer {
            if let old { Thread.current.threadDictionary["SleepSeal.operationBudget"] = old }
            else { Thread.current.threadDictionary.removeObject(forKey: "SleepSeal.operationBudget") }
        }
        return try action()
    }
}

// Drain output concurrently so even a verbose failed command cannot fill a pipe.
private final class CommandOutput {
    let lock = NSLock()
    var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; if bytes.count < 262144 { bytes.append(data.prefix(262144 - bytes.count)) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}
func command(_ path: String, _ args: [String], timeout: TimeInterval = 2) throws -> CommandResult {
    let available = min(timeout, OperationBudget.current?.remaining ?? timeout)
    guard available > 0 else { throw GuardFailure("Operation budget exhausted / 操作已超时") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe(), output = CommandOutput()
    process.standardOutput = pipe; process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
    defer { pipe.fileHandleForReading.readabilityHandler = nil }
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + available
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline && (OperationBudget.current?.remaining ?? 1) > 0 {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.05)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        throw GuardFailure("Command timed out / 命令超时：\(URL(fileURLWithPath: path).lastPathComponent)")
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    output.append(pipe.fileHandleForReading.readDataToEndOfFile())
    return CommandResult(status: process.terminationStatus, output: output.text)
}

final class JSONStore: GuardStore {
    let url: URL
    init() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SleepSeal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        url = dir.appendingPathComponent("pending.json")
    }
    func load() throws -> PendingState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PendingState.self, from: Data(contentsOf: url))
    }
    func save(_ state: PendingState) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

final class BluetoothControl {
    typealias SetPower = @convention(c) (Int32) -> Void
    private let handle: UnsafeMutableRawPointer?
    private let setter: SetPower?
    init() {
        handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
        if let handle, let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") {
            setter = unsafeBitCast(symbol, to: SetPower.self)
        } else { setter = nil }
    }
    var available: Bool { setter != nil && IOBluetoothHostController.default() != nil }
    func read() -> Bool? {
        guard let controller = IOBluetoothHostController.default() else { return nil }
        switch controller.powerState {
        case kBluetoothHCIPowerStateON: return true
        case kBluetoothHCIPowerStateOFF: return false
        default: return nil
        }
    }
    func set(_ enabled: Bool) throws {
        if read() == enabled { return }
        guard let setter else { throw GuardFailure("蓝牙控制接口不可用") }
        setter(enabled ? 1 : 0)
        for _ in 0..<15 {
            if let budget = OperationBudget.current, budget.remaining <= 0 { break }
            if read() == enabled { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw GuardFailure("无法切换蓝牙；请检查 SleepSeal 的蓝牙权限")
    }
}

final class MacSystem: GuardSystem {
    let bluetooth = BluetoothControl()
    private let wlan = CWWiFiClient.shared()

    func powerValues() throws -> [PowerValue] {
        let result = try command("/usr/bin/pmset", ["-g", "custom"])
        guard result.status == 0 else { throw GuardFailure("无法读取电源设置：\(result.output)") }
        return PowerPolicy.parse(result.output)
    }

    func readRadios() -> (wifi: [String: Bool], bluetooth: Bool?) {
        var wifi: [String: Bool] = [:]
        for interface in wlan.interfaces() ?? [] {
            if let name = interface.interfaceName { wifi[name] = interface.powerOn() }
        }
        return (wifi, bluetooth.read())
    }

    func capture() throws -> Snapshot {
        guard CBManager.authorization == .allowedAlways else { throw GuardFailure("Bluetooth permission is required / 需要蓝牙权限") }
        try PrivilegedPowerTool.verifyAuthorization()
        try PrivilegedPowerTool.claimProtection()
        var captured = false
        defer { if !captured { try? PrivilegedPowerTool.releaseProtection() } }
        let interfaces = wlan.interfaces() ?? []
        guard !interfaces.isEmpty else { throw GuardFailure("没有找到 Wi-Fi 接口") }
        var wifi: [String: Bool] = [:]
        for interface in interfaces {
            if let name = interface.interfaceName { wifi[name] = interface.powerOn() }
        }
        guard !wifi.isEmpty else { throw GuardFailure("无法读取 Wi-Fi 状态") }
        guard bluetooth.available, let bt = bluetooth.read() else {
            throw GuardFailure("无法读取蓝牙状态；请先运行权限检查")
        }
        let values = try powerValues()
        guard values.contains(where: { ["powermode", "lowpowermode"].contains($0.key) }) else {
            throw GuardFailure("此设备没有可识别的低电量模式设置，停止操作")
        }
        captured = true
        return Snapshot(wifi: wifi, bluetooth: bt, power: values)
    }

    private func setWiFi(_ name: String, _ enabled: Bool) throws {
        guard let interface = wlan.interface(withName: name) else {
            throw GuardFailure("找不到原来的 Wi-Fi 接口：\(name)")
        }
        if interface.powerOn() == enabled { return }
        try interface.setPower(enabled)
        guard interface.powerOn() == enabled else { throw GuardFailure("Wi-Fi 切换后状态不符") }
    }

    private func setPower(_ value: PowerValue, to target: Int) throws {
        let request = PowerValue(scope: value.scope, key: value.key, value: target)
        guard PowerPolicy.valid(request) else { throw GuardFailure("拒绝未允许的电源参数") }
        try PrivilegedPowerTool.set(scope: value.scope, key: value.key, value: target, restoring: true)
    }

    private func attempt(_ errors: inout [String], _ action: () throws -> Void) {
        do { try action() } catch { errors.append(String(describing: error)) }
    }

    func suppress(_ snapshot: Snapshot) throws {
        guard ConsoleSession.isConsoleOwner else { throw GuardFailure("This account is not the active console / 此账户不是当前控制台用户") }
        try PrivilegedPowerTool.claimProtection()
        var errors: [String] = []
        for name in snapshot.wifi.keys.sorted() { attempt(&errors) { try setWiFi(name, false) } }
        if snapshot.bluetooth != nil { attempt(&errors) { try bluetooth.set(false) } }
        var current: [PowerValue] = []
        attempt(&errors) { current = try powerValues() }
        for value in snapshot.power {
            let target = PowerPolicy.desired(value)
            if current.contains(PowerValue(scope: value.scope, key: value.key, value: target)) { continue }
            attempt(&errors) { try setPower(value, to: target) }
        }
        // A successful command is not proof that the OS accepted the mode.
        attempt(&errors) {
            let observed = try powerValues()
            for value in snapshot.power {
                guard observed.contains(PowerValue(scope: value.scope, key: value.key, value: PowerPolicy.desired(value))) else {
                    throw GuardFailure("电源设置未生效：\(value.scope) \(value.key)")
                }
            }
        }
        if !errors.isEmpty { throw GuardFailure(errors.joined(separator: "；")) }
    }

    func restore(_ snapshot: Snapshot) throws {
        guard ConsoleSession.isConsoleOwner else { throw GuardFailure("This account is not the active console / 此账户不是当前控制台用户") }
        try PrivilegedPowerTool.claimProtection()
        var errors: [String] = []
        // Restore power first, but attempt all restorations even if one fails.
        for value in snapshot.power { attempt(&errors) { try setPower(value, to: value.value) } }
        for (name, enabled) in snapshot.wifi { attempt(&errors) { try setWiFi(name, enabled) } }
        if let enabled = snapshot.bluetooth { attempt(&errors) { try bluetooth.set(enabled) } }
        attempt(&errors) {
            let observed = try powerValues()
            for value in snapshot.power where !observed.contains(value) {
                throw GuardFailure("恢复电源设置后状态不符：\(value.scope) \(value.key)")
            }
        }
        if !errors.isEmpty { throw GuardFailure(errors.joined(separator: "；")) }
    }
}

enum ConsoleSession {
    static var dictionary: [String: Any]? { CGSessionCopyCurrentDictionary() as? [String: Any] }
    static var locked: Bool { dictionary?["CGSSessionScreenIsLocked"] as? Bool == true }
    static var isConsoleOwner: Bool {
        guard let session = dictionary,
              let uid = session[kCGSessionUserIDKey as String] as? NSNumber else { return false }
        return uid.uint32Value == getuid() && session[kCGSessionOnConsoleKey as String] as? Bool == true
    }
    static var verified: Bool {
        guard let session = dictionary,
              let uid = session[kCGSessionUserIDKey as String] as? NSNumber,
              uid.uint32Value == getuid(),
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        // The undocumented lock key may be absent in an unlocked session.
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }
}
