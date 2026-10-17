import Foundation
import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import Darwin

struct BlockingAppsInventory {
    let assertions: [BlockingSleepAssertion]
    let applications: [BlockingAppIdentity]
}

struct BlockingAppsResult {
    var candidateCount = 0
    var requestedApps: [BlockingAppIdentity] = []
    var terminatedApps: [BlockingAppIdentity] = []
    /// Original selected applications that remain alive. A save dialog may
    /// release an assertion without closing its application.
    var remainingApps: [BlockingAppIdentity] = []
    var cancelled = false
    var timedOut = false
    var error: String?
    var requestedCount: Int { requestedApps.count }
    var terminatedCount: Int { terminatedApps.count }
    var remainingCount: Int { remainingApps.count }
}

enum BlockingQuitAttempt: Equatable {
    case requested, refused, stale, noLongerBlocking, cancelled, timedOut
    case unavailable(String)
}

enum BlockingProcessPresence { case original, gone, unknown }

/// The host boundary permits tests to simulate applications and main-queue
/// delays without querying, terminating or otherwise changing real processes.
protocol BlockingAppsHost: AnyObject {
    var currentUID: UInt32 { get }
    var ownPID: Int32 { get }
    func now() -> TimeInterval
    func isConsoleOwner() -> Bool
    func activeAssertions() throws -> [BlockingSleepAssertion]
    func application(pid: Int32) -> BlockingAppIdentity?
    func presence(of identity: BlockingAppIdentity) -> BlockingProcessPresence
    func normalQuit(_ identity: BlockingAppIdentity, permitted: () -> Bool) -> Bool
    func onMain(deadline: TimeInterval, cancelled: @escaping () -> Bool,
                action: @escaping (@escaping () -> Bool) -> BlockingQuitAttempt) -> BlockingQuitAttempt
    func waitBriefly(until deadline: TimeInterval)
}

enum BlockingAssertionReader {
    private static func exactInteger(_ object: Any) -> Int64? {
        guard let number = object as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        let value = number.int64Value
        guard number.doubleValue == Double(value) else { return nil }
        return value
    }

    /// The public IOPM API supplies CFNumber PID keys and typed assertion
    /// dictionaries. Never derive a target PID from pmset display strings.
    static func parse(_ dictionary: NSDictionary) -> [BlockingSleepAssertion] {
        var assertions: [BlockingSleepAssertion] = []
        let systemTypes: Set<String> = [kIOPMAssertPreventUserIdleSystemSleep as String,
            kIOPMAssertionTypePreventSystemSleep as String, kIOPMAssertionTypeNoIdleSleep as String]
        let displayTypes: Set<String> = [kIOPMAssertPreventUserIdleDisplaySleep as String,
            kIOPMAssertionTypeNoDisplaySleep as String]
        for (rawPID, rawAssertions) in dictionary {
            guard let pid = exactInteger(rawPID), pid > 0, pid <= Int64(Int32.max),
                  let entries = rawAssertions as? [NSDictionary] else { continue }
            for entry in entries {
                guard let rawLevel = entry[kIOPMAssertionLevelKey as String],
                      exactInteger(rawLevel) == Int64(kIOPMAssertionLevelOn),
                      let type = entry[kIOPMAssertionTypeKey as String] as? String else { continue }
                let kind: BlockingAssertionKind
                if systemTypes.contains(type) { kind = .system }
                else if displayTypes.contains(type) { kind = .display }
                else { continue }
                assertions.append(BlockingSleepAssertion(pid: Int32(pid), kind: kind))
            }
        }
        return assertions
    }

    static func read() throws -> [BlockingSleepAssertion] {
        var dictionary: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&dictionary)
        guard result == kIOReturnSuccess, let dictionary else {
            throw BlockingAppsFailure("Cannot read active power assertions / 无法读取当前电源断言 (\(result))")
        }
        return parse(dictionary.takeRetainedValue() as NSDictionary)
    }
}

struct BlockingAppsFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum BlockingApps {
    static func inventory(deadline: TimeInterval? = nil, cancelled: () -> Bool = { false }) throws -> BlockingAppsInventory {
        try inventory(host: NativeBlockingAppsHost(), deadline: deadline, cancelled: cancelled)
    }

    static func inventory(host: BlockingAppsHost, deadline: TimeInterval? = nil,
                          cancelled: () -> Bool = { false }, matching: [BlockingAppIdentity]? = nil) throws -> BlockingAppsInventory {
        guard host.isConsoleOwner() else { throw BlockingAppsFailure("This account is not the active console / 此账户不是当前控制台用户") }
        if cancelled() || deadline.map({ host.now() >= $0 }) == true {
            return BlockingAppsInventory(assertions: [], applications: [])
        }
        let assertions = try host.activeAssertions()
        let matchingPIDs = matching.map { Set($0.map(\.pid)) }
        var applications: [BlockingAppIdentity] = []
        for pid in Set(assertions.map(\.pid)).sorted() {
            if cancelled() || deadline.map({ host.now() >= $0 }) == true { break }
            if let matchingPIDs, !matchingPIDs.contains(pid) { continue }
            if let app = host.application(pid: pid) { applications.append(app) }
        }
        return BlockingAppsInventory(assertions: assertions,
            applications: BlockingAppsPolicy.select(assertions: assertions, applications: applications,
                currentUID: host.currentUID, ownPID: host.ownPID))
    }

    /// Call on the serialized background coordinator, never the UI thread.
    /// `cancelled` must be thread-safe because it is also checked immediately
    /// before the main-thread normal quit. `shouldRequest` runs only on the
    /// caller's serial queue and can claim the coordinator's attempt ledger.
    static func requestQuitBlockingApps(applications: [BlockingAppIdentity]? = nil,
        deadline: TimeInterval, cancelled: @escaping () -> Bool,
        shouldRequest: ((BlockingAppIdentity) -> Bool)? = nil) -> BlockingAppsResult {
        guard !Thread.isMainThread else {
            return BlockingAppsResult(error: "Quit preparation must run off the UI thread / 退出准备需要在后台运行")
        }
        return requestQuitBlockingApps(host: NativeBlockingAppsHost(), applications: applications,
            deadline: deadline, cancelled: cancelled, shouldRequest: shouldRequest)
    }

    static func requestQuitBlockingApps(host: BlockingAppsHost, applications: [BlockingAppIdentity]? = nil,
        deadline: TimeInterval, cancelled: @escaping () -> Bool,
        shouldRequest: ((BlockingAppIdentity) -> Bool)? = nil) -> BlockingAppsResult {
        var result = BlockingAppsResult()
        guard !cancelled() else { result.cancelled = true; return result }
        guard deadline.isFinite, host.now() < deadline else { result.timedOut = true; return result }
        let selected: [BlockingAppIdentity]
        do {
            let current = try inventory(host: host, deadline: deadline, cancelled: cancelled, matching: applications)
            selected = current.applications.filter { current in
                applications == nil || applications!.contains { BlockingAppsPolicy.sameProcess($0, current) }
            }
        } catch { result.error = String(describing: error); return result }
        result.candidateCount = selected.count
        result.remainingApps = selected
        for expected in selected {
            if cancelled() { result.cancelled = true; break }
            if host.now() >= deadline { result.timedOut = true; break }
            guard host.isConsoleOwner(), let current = host.application(pid: expected.pid),
                  BlockingAppsPolicy.sameProcess(expected, current) else { continue }
            do {
                let assertions = try host.activeAssertions()
                guard !BlockingAppsPolicy.select(assertions: assertions, applications: [current],
                    currentUID: host.currentUID, ownPID: host.ownPID).isEmpty else { continue }
            } catch { result.error = String(describing: error); break }
            guard !cancelled(), host.now() < deadline else { continue }
            guard shouldRequest?(current) ?? true else { continue }
            let attempt = host.onMain(deadline: deadline, cancelled: cancelled) { permitted in
                guard permitted() && !cancelled() else { return .cancelled }
                guard host.now() < deadline else { return .timedOut }
                guard host.isConsoleOwner(), let fresh = host.application(pid: expected.pid),
                      BlockingAppsPolicy.sameProcess(expected, fresh) else { return .stale }
                do {
                    let freshAssertions = try host.activeAssertions()
                    guard !BlockingAppsPolicy.select(assertions: freshAssertions, applications: [fresh],
                        currentUID: host.currentUID, ownPID: host.ownPID).isEmpty else { return .noLongerBlocking }
                } catch { return .unavailable(String(describing: error)) }
                guard permitted() && !cancelled() else { return .cancelled }
                guard host.now() < deadline else { return .timedOut }
                return host.normalQuit(expected, permitted: { permitted() && !cancelled() && host.now() < deadline })
                    ? .requested : .refused
            }
            switch attempt {
            case .requested: result.requestedApps.append(expected)
            case .cancelled: result.cancelled = true
            case .timedOut: result.timedOut = true
            case .unavailable(let error): result.error = error
            default: break
            }
            if result.cancelled || result.timedOut || result.error != nil { break }
        }
        // A successful request is not a closed application. Observe actual
        // process identity until all requested originals exit or time runs out.
        while !result.requestedApps.isEmpty && host.now() < deadline && !cancelled() {
            let waiting = result.requestedApps.filter { host.presence(of: $0) != .gone }
            if waiting.isEmpty { break }
            host.waitBriefly(until: deadline)
        }
        result.cancelled = result.cancelled || cancelled()
        result.terminatedApps = result.requestedApps.filter { host.presence(of: $0) == .gone }
        result.remainingApps = selected.filter { host.presence(of: $0) != .gone }
        result.timedOut = result.timedOut || (!result.cancelled && host.now() >= deadline && !result.remainingApps.isEmpty)
        return result
    }
}

final class BlockingMainQuitGate {
    private let lock = NSLock()
    private var open = true
    func close() { lock.lock(); open = false; lock.unlock() }
    var permitted: Bool { lock.lock(); defer { lock.unlock() }; return open }
}

private final class MainQuitResult {
    private let lock = NSLock()
    private var value: BlockingQuitAttempt = .timedOut
    func set(_ value: BlockingQuitAttempt) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> BlockingQuitAttempt { lock.lock(); defer { lock.unlock() }; return value }
}

private final class NativeBlockingAppsHost: BlockingAppsHost {
    var currentUID: UInt32 { getuid() }
    var ownPID: Int32 { getpid() }
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func isConsoleOwner() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let uid = session[kCGSessionUserIDKey as String] as? NSNumber else { return false }
        return uid.uint32Value == getuid() && session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session[kCGSessionLoginDoneKey as String] as? Bool == true
    }
    func activeAssertions() throws -> [BlockingSleepAssertion] { try BlockingAssertionReader.read() }

    private func processInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        return read == size ? info : nil
    }
    private func startDate(_ info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
    func application(pid: Int32) -> BlockingAppIdentity? {
        guard let before = processInfo(pid: pid), before.pbi_uid == currentUID,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.launchDate != nil, let executable = app.executableURL?.path,
              let after = processInfo(pid: pid), before.pbi_uid == after.pbi_uid,
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return BlockingAppIdentity(pid: pid, uid: after.pbi_uid, bundleID: app.bundleIdentifier ?? "",
            launchDate: startDate(after), displayName: app.localizedName ?? app.bundleIdentifier ?? "",
            activationRegular: app.activationPolicy == .regular, executablePath: executable)
    }
    func presence(of identity: BlockingAppIdentity) -> BlockingProcessPresence {
        if let info = processInfo(pid: identity.pid) {
            return info.pbi_uid == identity.uid && startDate(info) == identity.launchDate ? .original : .gone
        }
        // Failure to inspect a process is not proof of termination. A missing
        // kernel PID (ESRCH), or a positively terminated AppKit object, is.
        if errno == ESRCH { return .gone }
        if let app = NSRunningApplication(processIdentifier: identity.pid), app.isTerminated { return .gone }
        return .unknown
    }
    func normalQuit(_ identity: BlockingAppIdentity, permitted: () -> Bool) -> Bool {
        guard Thread.isMainThread, permitted(), isConsoleOwner(),
              let fresh = application(pid: identity.pid), BlockingAppsPolicy.sameProcess(identity, fresh),
              let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated,
              permitted() else { return false }
        return app.terminate()
    }
    func onMain(deadline: TimeInterval, cancelled: @escaping () -> Bool,
                action: @escaping (@escaping () -> Bool) -> BlockingQuitAttempt) -> BlockingQuitAttempt {
        guard !Thread.isMainThread, now() < deadline, !cancelled() else { return .cancelled }
        let gate = BlockingMainQuitGate(), result = MainQuitResult(), completion = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            defer { completion.signal() }
            guard gate.permitted, !cancelled(), self.now() < deadline else { return }
            result.set(action { gate.permitted && !cancelled() && self.now() < deadline })
        }
        while now() < deadline && !cancelled() {
            if completion.wait(timeout: .now() + min(0.025, max(0, deadline - now()))) == .success {
                gate.close(); return result.get()
            }
        }
        gate.close()
        // The main block may have completed exactly as cancellation or the
        // deadline ended the loop. Preserve its observed request result rather
        // than losing a successful send at that boundary. Never wait longer.
        if completion.wait(timeout: .now()) == .success { return result.get() }
        return cancelled() ? .cancelled : .timedOut
    }
    func waitBriefly(until deadline: TimeInterval) {
        Thread.sleep(forTimeInterval: min(0.025, max(0, deadline - now())))
    }
}
