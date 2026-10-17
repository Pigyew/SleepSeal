import Foundation

enum RuntimeLaunchPolicy {
    /// Starting the recovery owner must not require healthy optional settings.
    /// Never rewrite a damaged/future configuration just to start that owner.
    static func loginPreference(load: () throws -> AppConfiguration) -> Bool {
        (try? load())?.launchAtLogin ?? false
    }
}

/// Nonessential preferences must never prevent a valid recovery record loading.
struct RuntimeSettings {
    let configuration: AppConfiguration
    let preferences: PowerPreferencesManager?
    let configurationError: String?
    let preferencesError: String?
    var ready: Bool { configurationError == nil && preferencesError == nil }
    var issue: String? {
        let issues = [configurationError, preferencesError].compactMap { $0 }
        return issues.isEmpty ? nil : issues.joined(separator: "\n")
    }

    static func load(configuration: () throws -> AppConfiguration,
                     preferences: () throws -> PowerPreferencesManager) -> RuntimeSettings {
        var loaded = AppConfiguration(onboardingCompleted: false, protectionPaused: true)
        var configurationError: String?
        var preferencesError: String?
        var manager: PowerPreferencesManager?
        do { loaded = try configuration() }
        catch { configurationError = "Saved app settings need repair; new protection is paused. Existing connections can still be restored. / 应用设置需要修复，已暂停新的保护，仍可恢复现有连接。\n\(error)" }
        do { manager = try preferences() }
        catch { preferencesError = "Saved power settings need repair; new protection and power edits are paused. Existing connections can still be restored. / 电源备份需要修复，已暂停新的保护和电源编辑，仍可恢复现有连接。\n\(error)" }
        return RuntimeSettings(configuration: loaded, preferences: manager,
                               configurationError: configurationError, preferencesError: preferencesError)
    }
}

/// Refreshes replace diagnostic errors, never an outstanding recovery failure.
struct RuntimeFailures {
    var startup: String?
    var registration: String?
    var operation: String?
    var diagnostic: String?
    var message: String? {
        let values = [startup, registration, operation, diagnostic].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }
}

enum RuntimeRefreshCadence {
    static func interval(pending: Bool, dashboardVisible: Bool) -> TimeInterval {
        pending || dashboardVisible ? 10 : 60
    }
}

/// Capture at notification receipt. A later sleep or re-lock invalidates queued
/// unlock work before it can acquire the current recovery cycle's identity.
final class UnlockEventFence {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    func invalidate() { lock.lock(); generation &+= 1; lock.unlock() }
    func capture() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func accepts(_ token: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return token == generation }
}

/// Only corner occupancy transitions matter to the entry tracker. Keep the
/// event timestamp while avoiding queue work for every pixel of mouse motion.
struct HotCornerPointerFilter {
    private var previous: Set<String>?
    mutating func shouldSubmit(point: HotCornerPoint, screens: [HotCornerScreen]) -> Bool {
        let occupied = Set(screens.compactMap { screen -> String? in
            screen.corner(at: point).map { "\(screen.id):\($0.rawValue)" }
        })
        defer { previous = occupied }
        return previous != occupied
    }
}
