import Foundation
import Darwin

enum HelperOperation: Equatable {
    case check
    case claim
    case release
    case set(scope: String, key: String, value: Int, restoring: Bool)
    case finalizeMigration
    case uninstall
}

struct HelperRejection: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Keep this parser independent of authorization and execution so every accepted
/// operation is exercised without running pmset, sudo, or an uninstaller.
enum HelperPolicy {
    static let installedPath = "/Library/PrivilegedHelperTools/local.sleepseal.PowerControl"
    static let appPath = "/Applications/SleepSeal.app"
    static let receiptDirectory = "/Library/Application Support/SleepSeal/authorized-users"
    static let protectionOwnerPath = "/Library/Application Support/SleepSeal/protection-owner"
    static let protectionLockPath = "/Library/Application Support/SleepSeal/protection-lock"
    static let binaryKeys: Set<String> = ["powernap", "tcpkeepalive", "womp", "proximitywake"]

    static func parse(_ args: [String]) throws -> HelperOperation {
        if args == ["check"] { return .check }
        if args == ["claim"] { return .claim }
        if args == ["release"] { return .release }
        if args == ["uninstall"] { return .uninstall }
        if args == ["finalize-migration"] { return .finalizeMigration }
        guard args.count == 4, args[0] == "set" || args[0] == "restore",
              args[1] == "b" || args[1] == "c",
              !args[3].isEmpty, args[3].utf8.allSatisfy({ (48...57).contains($0) }),
              args[3] == "0" || !args[3].hasPrefix("0"),
              let value = Int(args[3]), value <= Int(Int32.max) else {
            throw HelperRejection("Invalid fixed power-control arguments.")
        }
        let restoring = args[0] == "restore"
        let key = args[2]
        let accepted: Bool
        switch key {
        case "displaysleep", "sleep": accepted = restoring || value <= 1440
        case "powermode": accepted = value <= 2
        case "lowpowermode": accepted = value <= 1
        default: accepted = binaryKeys.contains(key) && value <= 1
        }
        guard accepted else { throw HelperRejection("The setting or value is outside the allowlist.") }
        return .set(scope: args[1] == "b" ? "-b" : "-c", key: key, value: value, restoring: restoring)
    }
}

enum HelperLeasePolicy {
    static func mayClaim(owner: uid_t?, requester: uid_t) -> Bool { owner == nil || owner == requester }
    static func mayRelease(owner: uid_t?, requester: uid_t) -> Bool { owner == nil || owner == requester }
    static func mayUninstall(owner: uid_t?, requester: uid_t) -> Bool { owner != requester }
}

/// Validate the literal trusted installation path one component at a time.
/// Standardizing a file URL can rewrite /private/etc to /etc on macOS, which
/// would inspect the system's /etc symlink rather than the intended directory.
/// This verifier is shared with read-only regression tests; it never writes.
enum RootPathVerifier {
    static func components(of path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == "." || $0 == ".." }) else {
            throw HelperRejection("A privileged installation path must be an absolute literal path.")
        }
        return URL(fileURLWithPath: path).pathComponents
    }

    static func verify(_ path: String, requireRegularFile: Bool = false) throws {
        let components = try components(of: path)
        var current = ""
        for (index, component) in components.enumerated() {
            current = component == "/" ? "/" : (current as NSString).appendingPathComponent(component)
            var metadata = stat()
            guard lstat(current, &metadata) == 0, metadata.st_uid == 0,
                  metadata.st_mode & 0o022 == 0, metadata.st_mode & S_IFMT != S_IFLNK else {
                throw HelperRejection("A privileged installation path is not root-owned and protected.")
            }
            if index == components.count - 1, requireRegularFile, metadata.st_mode & S_IFMT != S_IFREG {
                throw HelperRejection("The privileged tool is not a regular file.")
            }
        }
    }
}

#if !HELPER_POLICY_TESTING
private enum PowerControl {
    static func verifyRootPath(_ path: String, requireRegularFile: Bool = false) throws {
        try RootPathVerifier.verify(path, requireRegularFile: requireRegularFile)
    }

    static func caller() throws -> (uid_t, String) {
        guard getuid() == 0, geteuid() == 0,
              let uidText = ProcessInfo.processInfo.environment["SUDO_UID"],
              !uidText.isEmpty, uidText.utf8.allSatisfy({ (48...57).contains($0) }),
              let uid = UInt32(uidText), uid >= 500,
              let account = getpwuid(uid),
              let namePointer = account.pointee.pw_name else {
            throw HelperRejection("Run this tool through the installed SleepSeal authorization rule.")
        }
        let name = String(cString: namePointer)
        guard ProcessInfo.processInfo.environment["SUDO_USER"] == name else {
            throw HelperRejection("The requesting account does not match its user ID.")
        }
        try verifyRootPath(HelperPolicy.installedPath, requireRegularFile: true)
        let record = "\(HelperPolicy.receiptDirectory)/\(uid)"
        try verifyRootPath(record, requireRegularFile: true)
        let contents = try String(contentsOfFile: record, encoding: .utf8)
        guard contents == "\(uid)\n" else { throw HelperRejection("The installation authorization record is invalid.") }
        return (uid, name)
    }

    static func withProtectionLock<T>(_ action: () throws -> T) throws -> T {
        try verifyRootPath("/Library/Application Support/SleepSeal")
        let descriptor = open(HelperPolicy.protectionLockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HelperRejection("Cannot open the protected sleep-cycle lock.") }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
              metadata.st_nlink == 1 else {
            throw HelperRejection("The protected sleep-cycle lock is not a private root-owned file.")
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw HelperRejection("Cannot lock the sleep-cycle owner record.") }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    static func protectionOwner() throws -> uid_t? {
        var metadata = stat()
        if lstat(HelperPolicy.protectionOwnerPath, &metadata) != 0 {
            if errno == ENOENT { return nil }
            throw HelperRejection("Cannot read the protected sleep-cycle owner record.")
        }
        try verifyRootPath(HelperPolicy.protectionOwnerPath, requireRegularFile: true)
        guard metadata.st_nlink == 1, metadata.st_size <= 16 else {
            throw HelperRejection("The protected sleep-cycle owner record is invalid.")
        }
        let text = try String(contentsOfFile: HelperPolicy.protectionOwnerPath, encoding: .utf8)
        guard text.hasSuffix("\n"), let uid = UInt32(text.dropLast()), uid >= 500,
              text == "\(uid)\n" else {
            throw HelperRejection("The protected sleep-cycle owner record is invalid.")
        }
        return uid
    }

    static func claim(uid: uid_t) throws {
        try withProtectionLock {
            let owner = try protectionOwner()
            guard HelperLeasePolicy.mayClaim(owner: owner, requester: uid) else {
                throw HelperRejection("Another Mac account has an unfinished SleepSeal recovery. Switch to that account and restore it first. / 另一账户仍有未完成的 SleepSeal 恢复，请切换到该账户先恢复。")
            }
            if owner == nil {
                try Data("\(uid)\n".utf8).write(to: URL(fileURLWithPath: HelperPolicy.protectionOwnerPath), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HelperPolicy.protectionOwnerPath)
            }
            print("SleepSeal protection belongs to this account.")
        }
    }

    static func release(uid: uid_t) throws {
        try withProtectionLock {
            let owner = try protectionOwner()
            guard HelperLeasePolicy.mayRelease(owner: owner, requester: uid) else {
                // No pending cycle in this account must not revoke another
                // account's protection or cause repeated refresh errors.
                print("Another account owns the pending SleepSeal cycle; it was left unchanged.")
                return
            }
            if owner != nil { try FileManager.default.removeItem(atPath: HelperPolicy.protectionOwnerPath) }
            print("SleepSeal protection ownership was released.")
        }
    }

    static func set(scope: String, key: String, value: Int, uid: uid_t) throws {
        try withProtectionLock {
            let owner = try protectionOwner()
            if key != "displaysleep" && key != "sleep" && !HelperLeasePolicy.mayClaim(owner: owner, requester: uid) {
                throw HelperRejection("Another account has a pending SleepSeal cycle. Its power mode was left unchanged. / 另一账户有待恢复周期，未更改其电源模式。")
            }
            try executePMSet(scope: scope, key: key, value: value)
        }
    }

    static func executePMSet(scope: String, key: String, value: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = [scope, key, String(value)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw HelperRejection("The system power-setting request timed out.")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw HelperRejection("macOS rejected the requested power setting (exit \(process.terminationStatus)): \(String(decoding: output, as: UTF8.self).prefix(1024))")
        }
    }

    static func finalizeMigration(uid: uid_t) throws {
        let legacyRule = "/private/etc/sudoers.d/sleepseal_\(uid)"
        guard FileManager.default.fileExists(atPath: legacyRule) else { return }
        try verifyRootPath(legacyRule, requireRegularFile: true)
        try FileManager.default.removeItem(atPath: legacyRule)
    }

    static func uninstall(uid: uid_t) throws {
        try withProtectionLock { try uninstallWhileLocked(uid: uid) }
    }

    static func uninstallWhileLocked(uid: uid_t) throws {
        let manager = FileManager.default
        let owner = try protectionOwner()
        guard HelperLeasePolicy.mayUninstall(owner: owner, requester: uid) else {
            throw HelperRejection("Restore the pending SleepSeal cycle and release it before uninstalling. / 请先恢复并释放待恢复周期，再卸载。")
        }
        let ownRuleNames = ["sleepseal_\(uid)", "sleepseal_v2_\(uid)"]
        let ownRules = ownRuleNames.map { "/private/etc/sudoers.d/\($0)" }
        let ownRecord = "\(HelperPolicy.receiptDirectory)/\(uid)"
        var ruleBytes: [String: Data] = [:]
        for rule in ownRules where manager.fileExists(atPath: rule) {
            try verifyRootPath(rule, requireRegularFile: true)
            ruleBytes[rule] = try Data(contentsOf: URL(fileURLWithPath: rule))
        }
        let remainingRecords = try manager.contentsOfDirectory(atPath: HelperPolicy.receiptDirectory)
            .filter { $0 != String(uid) }
        let remainingRules = try manager.contentsOfDirectory(atPath: "/private/etc/sudoers.d")
            .filter { $0.hasPrefix("sleepseal_") && !ownRuleNames.contains($0) }
        let sharedInstallationInUse = owner != nil || !remainingRecords.isEmpty || !remainingRules.isEmpty
        // Another user's background agent may still need the shared installation.
        if !sharedInstallationInUse, manager.fileExists(atPath: HelperPolicy.appPath) {
            // /Applications may intentionally be writable by the admin group.
            // The helper itself is below a strictly protected /Library path;
            // deletion is limited to this fixed, root-owned application bundle.
            var metadata = stat()
            guard lstat(HelperPolicy.appPath, &metadata) == 0, metadata.st_uid == 0,
                  metadata.st_mode & 0o022 == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  let info = NSDictionary(contentsOfFile: HelperPolicy.appPath + "/Contents/Info.plist"),
                  info["CFBundleIdentifier"] as? String == "local.sleepseal.guard" else {
                throw HelperRejection("The installed application could not be safely identified; it was left in place.")
            }
            try manager.removeItem(atPath: HelperPolicy.appPath)
        }
        do {
            try manager.removeItem(atPath: ownRecord)
            for rule in ruleBytes.keys { try manager.removeItem(atPath: rule) }
            if !sharedInstallationInUse { try manager.removeItem(atPath: HelperPolicy.installedPath) }
        } catch {
            // If final cleanup fails, retain authorization so the user process
            // can retry. Only fixed, previously verified root files are restored.
            try? Data("\(uid)\n".utf8).write(to: URL(fileURLWithPath: ownRecord), options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ownRecord)
            for (rule, bytes) in ruleBytes {
                try? bytes.write(to: URL(fileURLWithPath: rule), options: .atomic)
                try? manager.setAttributes([.posixPermissions: 0o440], ofItemAtPath: rule)
            }
            throw error
        }
        print(sharedInstallationInUse
              ? "Removed this user's authorization; the shared installation is still used by another account."
              : "Removed the shared SleepSeal app and privileged tool. User settings and diagnostic files were preserved.")
    }
}

@main
private struct PowerControlMain {
    static func main() {
        do {
            // Parse before authorization. Unknown operations never reach root work.
            let operation = try HelperPolicy.parse(Array(CommandLine.arguments.dropFirst()))
            let (uid, _) = try PowerControl.caller()
            switch operation {
            case .check: print("SleepSeal power helper authorization is available.")
            case .claim: try PowerControl.claim(uid: uid)
            case .release: try PowerControl.release(uid: uid)
            case let .set(scope, key, value, _): try PowerControl.set(scope: scope, key: key, value: value, uid: uid)
            case .finalizeMigration: try PowerControl.finalizeMigration(uid: uid)
            case .uninstall: try PowerControl.uninstall(uid: uid)
            }
        } catch {
            FileHandle.standardError.write(Data("SleepSeal PowerControl: \(error)\n".utf8))
            exit(64)
        }
    }
}
#endif
