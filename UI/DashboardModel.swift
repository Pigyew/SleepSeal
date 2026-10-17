import AppKit
import SwiftUI

enum UILanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var localeIdentifier: String {
        switch self {
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        default: return rawValue
        }
    }
}

enum DashboardPage: String, CaseIterable, Identifiable {
    case overview, protection, power, diagnostics, settings
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "shield.lefthalf.filled"
        case .protection: return "switch.2"
        case .power: return "battery.75percent"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

enum UITrigger: String, CaseIterable, Identifiable {
    case manual, lid, hotCorner, idle
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .manual: return "moon.zzz"
        case .lid: return "laptopcomputer"
        case .hotCorner: return "arrow.up.left.and.arrow.down.right"
        case .idle: return "clock"
        }
    }
}

struct UITriggerPolicy: Equatable {
    var allSources = true
    var sources = Set(UITrigger.allCases)
    var allConfiguredCorners = true
    var selectedCorners = Set(["tl", "tr", "bl", "br"])
}

enum UIPowerScope: String, CaseIterable, Identifiable {
    case battery, adapter
    var id: String { rawValue }
    var commandFlag: String { self == .battery ? "-b" : "-c" }
}

struct UIPowerEdit: Equatable {
    let scope: UIPowerScope
    let key: String
    let original: Int
    let value: Int
}

struct UIPowerProfile: Equatable {
    var values: [String: Int] = [:]
    /// Canonical values: 0 = Automatic, 1 = Low power, 2 = High power.
    var supportedModes: [Int] = []
    var modeKey: String? = nil
    var available = false
}

struct UICorner: Identifiable, Equatable {
    let id: String
    var action: Int?
    var modifierSymbols: String
    init(id: String, action: Int? = nil, modifierSymbols: String = "") {
        self.id = id
        self.action = action
        self.modifierSymbols = modifierSymbols
    }
    var isSleep: Bool { action == 10 }
}

enum UIActualState: Equatable {
    case on, off, unknown, unavailable
    var key: String {
        switch self {
        case .on: return "state.on"
        case .off: return "state.off"
        case .unknown: return "state.unknown"
        case .unavailable: return "state.unavailable"
        }
    }
}

struct UIPermission: Identifiable {
    let id: String
    var titleKey: String
    var detailKey: String
    var ready: Bool
    var action: DashboardAction?
}

enum DashboardAction {
    case refresh
    case enableProtection
    case savePolicy(UITriggerPolicy)
    case sleepNow
    case displayOff
    case restoreProtection
    case setPaused(Bool)
    case setLogin(Bool)
    case setLanguage(UILanguage)
    case openHotCorners
    case openBluetoothSettings
    case repairInstallation
    case exportDiagnostics
    case uninstall(restorePower: Bool)
    case applyPower([UIPowerEdit])
    case restorePower
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var page: DashboardPage = .overview
    @Published var language: UILanguage = .system
    @Published var onboardingRequired = false
    @Published var isEnabled = false
    @Published var isPaused = false
    @Published var isBusy = false
    @Published var serviceAvailable = true
    @Published var guardPending = false
    @Published var loginEnabled = false
    @Published var statusKey = "guard.checking"
    @Published var detailKey = "guard.checking.detail"
    @Published var wifi: UIActualState = .unknown
    @Published var bluetooth: UIActualState = .unknown
    @Published var lowPower: UIActualState = .unknown
    @Published var lastTriggerKey = "event.none"
    @Published var lastTriggerDetail = ""
    @Published var lastRecoveryKey = "event.none"
    @Published var lastRecoveryDetail = ""
    @Published var feedbackKey: String? = nil
    @Published var feedbackDetail = ""
    @Published var feedbackIsError = false
    @Published var policy = UITriggerPolicy()
    @Published var savedPolicy = UITriggerPolicy()
    @Published var corners = [UICorner(id: "tl"), UICorner(id: "tr"), UICorner(id: "bl"), UICorner(id: "br")]
    @Published var powerProfiles: [UIPowerScope: UIPowerProfile] = [:]
    @Published var powerDrafts: [String: String] = [:]
    @Published var powerLoaded = false
    @Published var powerConflict = false
    @Published var hasPowerBackup = false
    @Published var powerErrorKey: String? = nil
    @Published var permissions: [UIPermission] = []
    @Published var sleepBlockers: [String] = []
    @Published var blockersLoaded = false
    @Published var appVersion = "0.2.0 Beta"
    var onAction: ((DashboardAction) -> Void)?

    func text(_ key: String) -> String { L10n.text(key, language: language) }
    func send(_ action: DashboardAction) { onAction?(action) }
    var policyDirty: Bool { policy != savedPolicy }
    var canUseActions: Bool { serviceAvailable && !isBusy && isEnabled && !onboardingRequired }
    var powerDirty: Bool { !powerDrafts.isEmpty }

    func draftID(_ scope: UIPowerScope, _ key: String) -> String { "\(scope.rawValue).\(key)" }
    func draft(_ scope: UIPowerScope, _ key: String) -> String {
        powerDrafts[draftID(scope, key)] ?? powerProfiles[scope]?.values[key].map(String.init) ?? ""
    }
    func setDraft(_ value: String, scope: UIPowerScope, key: String) {
        let id = draftID(scope, key)
        if let original = powerProfiles[scope]?.values[key], value == String(original) {
            powerDrafts.removeValue(forKey: id)
        } else {
            powerDrafts[id] = value
        }
        powerErrorKey = nil
    }
    func powerEdits() -> [UIPowerEdit]? {
        var edits: [UIPowerEdit] = []
        for scope in UIPowerScope.allCases {
            guard let profile = powerProfiles[scope] else { continue }
            for (key, original) in profile.values {
                guard let draft = powerDrafts[draftID(scope, key)] else { continue }
                guard let value = Int(draft), String(value) == draft.trimmingCharacters(in: .whitespaces) else { return nil }
                if key == "displaysleep" || key == "sleep" {
                    guard (0...1440).contains(value) else { return nil }
                } else {
                    guard key == profile.modeKey, profile.supportedModes.contains(value) else { return nil }
                }
                edits.append(UIPowerEdit(scope: scope, key: key, original: original, value: value))
            }
        }
        return edits
    }
    func applyPower() {
        guard !isBusy, !powerConflict else { return }
        guard let edits = powerEdits(), !edits.isEmpty else {
            powerErrorKey = "power.validation"
            return
        }
        if guardPending && edits.contains(where: { $0.key == powerProfiles[$0.scope]?.modeKey }) {
            powerErrorKey = "power.modeLocked"
            return
        }
        send(.applyPower(edits))
    }

    /// GUI previews and screenshots use this model; all actions stay local.
    static func mock(language: UILanguage = .english, page: DashboardPage = .overview) -> DashboardModel {
        let model = DashboardModel()
        model.language = language
        model.page = page
        model.isEnabled = true
        model.statusKey = "guard.ready"
        model.detailKey = "guard.ready.detail"
        model.wifi = .on
        model.bluetooth = .on
        model.lowPower = .off
        model.lastTriggerKey = "trigger.lid"
        model.lastTriggerDetail = "10:42"
        model.lastRecoveryKey = "recovery.unlocked"
        model.lastRecoveryDetail = "10:44"
        model.corners = [UICorner(id: "tl"), UICorner(id: "tr", action: 10), UICorner(id: "bl"), UICorner(id: "br", action: 14)]
        model.powerProfiles = [.battery: UIPowerProfile(values: ["displaysleep": 5, "sleep": 10, "powermode": 0], supportedModes: [0, 1], modeKey: "powermode", available: true), .adapter: UIPowerProfile(values: ["displaysleep": 15, "sleep": 30, "powermode": 0], supportedModes: [0, 1, 2], modeKey: "powermode", available: true)]
        model.powerLoaded = true
        model.blockersLoaded = true
        model.permissions = [UIPermission(id: "bluetooth", titleKey: "permission.bluetooth", detailKey: "permission.ready", ready: true, action: nil), UIPermission(id: "helper", titleKey: "permission.helper", detailKey: "permission.ready", ready: true, action: nil)]
        model.onAction = { [weak model] action in
            guard let model else { return }
            switch action {
            case .savePolicy(let policy): model.savedPolicy = policy
            case .setPaused(let paused): model.isPaused = paused
            case .setLogin(let enabled): model.loginEnabled = enabled
            case .setLanguage(let language): model.language = language
            case .enableProtection: model.onboardingRequired = false; model.isEnabled = true
            default: model.feedbackKey = "mock.action"; model.feedbackIsError = false
            }
        }
        return model
    }
}
