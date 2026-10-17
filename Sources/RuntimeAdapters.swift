import Foundation
import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import Darwin

enum PrivilegedPowerTool {
    static let path = "/Library/PrivilegedHelperTools/local.sleepseal.PowerControl"
    static func verifyInstallation() throws {
        for component in ["/Library", "/Library/PrivilegedHelperTools", path] {
            var info = stat()
            guard lstat(component, &info) == 0, info.st_uid == 0,
                  (info.st_mode & 0o022) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
                throw GuardFailure("Reinstall the power helper with the SleepSeal installer / 请使用 SleepSeal 安装器修复电源工具")
            }
        }
        guard FileManager.default.isExecutableFile(atPath: path) else { throw GuardFailure("Power helper is unavailable / 电源工具不可用") }
    }
    static func verifyAuthorization() throws {
        try verifyInstallation()
        let result = try command("/usr/bin/sudo", ["-n", path, "check"])
        guard result.status == 0 else { throw GuardFailure("Power helper authorization is missing for this account / 此账户尚未授权电源工具，请重新运行安装器") }
    }
    static func claimProtection() throws {
        try verifyInstallation()
        let result = try command("/usr/bin/sudo", ["-n", path, "claim"])
        guard result.status == 0 else { throw GuardFailure("Another account has a pending protection cycle. Switch back to that account and restore first. / 另一账户存在待恢复保护，请切回该账户先恢复。") }
    }
    static func releaseProtection() throws {
        try verifyInstallation()
        let result = try command("/usr/bin/sudo", ["-n", path, "release"])
        guard result.status == 0 else { throw GuardFailure("Protection ownership cleanup needs retry / 保护权限清理需要重试") }
    }
    static func finalizeMigration() throws {
        try verifyAuthorization()
        let result = try command("/usr/bin/sudo", ["-n", path, "finalize-migration"])
        guard result.status == 0 else { throw GuardFailure("Migration cleanup needs retry / 迁移清理需要重试") }
    }
    static func set(scope: String, key: String, value: Int, restoring: Bool = false) throws {
        try verifyInstallation()
        guard ["-b", "-c"].contains(scope) else { throw GuardFailure("Invalid power source / 无效电源来源") }
        let result = try command("/usr/bin/sudo", ["-n", path, restoring ? "restore" : "set", scope == "-b" ? "b" : "c", key, String(value)])
        guard result.status == 0 else { throw GuardFailure("Power setting failed / 电源设置失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }
}

/// Owned by the state queue. Capabilities change infrequently; actual settings
/// are always read again, including every compare-and-swap and verification.
final class MacPowerPreferencesAdapter: PowerPreferencesAdapter {
    private var capabilities: String?
    private var capabilitiesReadAt: TimeInterval = -.infinity
    func read() throws -> PowerPreferencesSnapshot {
        let settings = try command("/usr/bin/pmset", ["-g", "custom"])
        guard settings.status == 0 else { throw GuardFailure("Cannot read power settings / 无法读取电源设置") }
        let now = ProcessInfo.processInfo.systemUptime
        if capabilities == nil || now - capabilitiesReadAt >= 300 {
            let result = try command("/usr/bin/pmset", ["-g", "cap"])
            guard result.status == 0 else { throw GuardFailure("Cannot read power capabilities / 无法读取电源能力") }
            capabilities = result.output; capabilitiesReadAt = now
        }
        return PowerPreferencesSnapshot.parse(custom: settings.output, capabilities: capabilities ?? "")
    }
    func write(_ value: PowerPreferenceValue, restoring: Bool) throws {
        try PrivilegedPowerTool.set(scope: value.source.rawValue, key: value.key.rawValue, value: value.value, restoring: restoring)
    }
}

enum LidState {
    static var closed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }
}

final class LidObserver {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    var changed: ((Bool, Bool) -> Void)?
    func start() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, type, argument in
            guard let context else { return }
            let observer = Unmanaged<LidObserver>.fromOpaque(context).takeUnretainedValue()
            // iokit_family_msg(sub_iokit_powermanagement, 0x100)
            guard type == 0xe0034100 else { return }
            let bits = Int(bitPattern: argument)
            observer.changed?((bits & 1) != 0, (bits & 2) != 0)
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
    }
    deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if let port { IONotificationPortDestroy(port) }
    }
}

enum SleepBlockers {
    static func parse(_ text: String) -> [String] {
        // Owner lines contain pid/process/assertion reason. Network names and
        // session identifiers are neither collected nor exported.
        text.components(separatedBy: .newlines).filter {
            $0.contains("pid ") && ($0.contains("PreventUserIdle") || $0.contains("PreventSystemSleep") || $0.contains("NoIdleSleep"))
        }.map { String($0.trimmingCharacters(in: .whitespaces).prefix(400)) }
    }
}
