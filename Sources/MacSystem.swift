import AppKit
import CoreWLAN
import IOBluetooth
import CoreGraphics
import Darwin

struct GuardFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

struct CommandResult { let status: Int32; let output: String }

// No shell is used, and a hung pmset cannot indefinitely delay sleep.
func command(_ path: String, _ args: [String], timeout: TimeInterval = 2) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.05)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        throw GuardFailure("命令超时：\(path)")
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return CommandResult(status: process.terminationStatus, output: output)
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

enum PowerPolicy {
    static let binaryKeys: Set<String> = ["powernap", "tcpkeepalive", "womp", "proximitywake"]

    static func valid(_ value: PowerValue) -> Bool {
        guard ["-b", "-c"].contains(value.scope) else { return false }
        if value.key == "powermode" { return (0...2).contains(value.value) }
        if value.key == "lowpowermode" || binaryKeys.contains(value.key) {
            return (0...1).contains(value.value)
        }
        return false
    }

    static func desired(_ value: PowerValue) -> Int {
        ["powermode", "lowpowermode"].contains(value.key) ? 1 : 0
    }

    // Parse each power source independently; preserve High Power Mode (2) too.
    static func parse(_ text: String) -> [PowerValue] {
        var scope: String?
        var values: [PowerValue] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "Battery Power:" { scope = "-b"; continue }
            if line == "AC Power:" { scope = "-c"; continue }
            if line.hasSuffix(":") { scope = nil; continue }
            guard let source = scope else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let number = Int(fields[1]) else { continue }
            let value = PowerValue(scope: source, key: String(fields[0]), value: number)
            if valid(value) { values.append(value) }
        }
        let modernSources = Set(values.filter { $0.key == "powermode" }.map(\.scope))
        return values.filter { !($0.key == "lowpowermode" && modernSources.contains($0.scope)) }
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

    func capture() throws -> Snapshot {
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
        let result = try command("/usr/bin/sudo", ["-n", "/usr/bin/pmset", value.scope, value.key, String(target)])
        guard result.status == 0 else {
            throw GuardFailure("电源设置失败（\(value.scope) \(value.key)）：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func attempt(_ errors: inout [String], _ action: () throws -> Void) {
        do { try action() } catch { errors.append(String(describing: error)) }
    }

    func suppress(_ snapshot: Snapshot) throws {
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
