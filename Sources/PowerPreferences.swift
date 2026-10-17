import Foundation

enum PowerSource: String, Codable, CaseIterable, Identifiable {
    case battery = "-b"
    case adapter = "-c"
    var id: String { rawValue }
    var helperArgument: String { self == .battery ? "b" : "c" }
}

enum PowerSettingKey: String, Codable, CaseIterable, Identifiable {
    case displaySleep = "displaysleep"
    case systemSleep = "sleep"
    case powerMode = "powermode"
    case lowPowerMode = "lowpowermode"
    var id: String { rawValue }
    var isEnergyMode: Bool { self == .powerMode || self == .lowPowerMode }
    var isTimer: Bool { !isEnergyMode }
}

struct PowerPreferenceValue: Codable, Equatable, Hashable, Identifiable {
    let source: PowerSource
    let key: PowerSettingKey
    let value: Int
    var id: String { "\(source.rawValue):\(key.rawValue)" }
    func replacingValue(_ newValue: Int) -> Self { Self(source: source, key: key, value: newValue) }
}

struct PowerPreferencesSnapshot: Codable, Equatable {
    var values: [PowerPreferenceValue]
    /// Only modes verified as available by the platform adapter belong here.
    /// A modern `powermode` key alone does not prove High Power Mode support.
    var supportedEnergyModes: [PowerSource: [Int]]
    init(values: [PowerPreferenceValue], supportedEnergyModes: [PowerSource: [Int]] = [:]) {
        self.values = values.sorted { $0.id < $1.id }
        self.supportedEnergyModes = supportedEnergyModes
    }
    func value(source: PowerSource, key: PowerSettingKey) -> PowerPreferenceValue? {
        values.first { $0.source == source && $0.key == key }
    }
    func matching(_ other: PowerPreferenceValue) -> PowerPreferenceValue? {
        value(source: other.source, key: other.key)
    }
    func energyMode(source: PowerSource) -> PowerPreferenceValue? {
        value(source: source, key: .powerMode) ?? value(source: source, key: .lowPowerMode)
    }

    static func parse(custom text: String, capabilities: String = "") -> Self {
        var source: PowerSource?
        var found: [String: PowerPreferenceValue] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Battery Power:" { source = .battery; continue }
            if line == "AC Power:" { source = .adapter; continue }
            if line.hasSuffix(":") { source = nil; continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let source, parts.count == 2,
                  let key = PowerSettingKey(rawValue: String(parts[0])),
                  let value = Int(parts[1]), value >= 0, value <= Int(Int32.max) else { continue }
            let entry = PowerPreferenceValue(source: source, key: key, value: value)
            found[entry.id] = entry
        }
        // macOS versions may report both aliases; edits must use one key.
        for source in PowerSource.allCases where found["\(source.rawValue):powermode"] != nil {
            found.removeValue(forKey: "\(source.rawValue):lowpowermode")
        }
        var modes: [PowerSource: [Int]] = [:]
        var capabilitySource: PowerSource?
        var highPowerSources = Set<PowerSource>()
        for rawLine in capabilities.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Capabilities for Battery Power:" { capabilitySource = .battery; continue }
            if line == "Capabilities for AC Power:" { capabilitySource = .adapter; continue }
            if line.hasSuffix(":") { capabilitySource = nil; continue }
            if let capabilitySource, line == "highpowermode" { highPowerSources.insert(capabilitySource) }
        }
        for source in PowerSource.allCases {
            let key = found["\(source.rawValue):powermode"] ?? found["\(source.rawValue):lowpowermode"]
            if let key, (0...2).contains(key.value) {
                modes[source] = key.key == .powerMode && (key.value == 2 || highPowerSources.contains(source))
                    ? [0, 1, 2] : [0, 1]
            }
        }
        return Self(values: Array(found.values), supportedEnergyModes: modes)
    }
}

struct PowerPreferenceEdit: Equatable {
    let original: PowerPreferenceValue
    let target: Int
}

protocol PowerPreferencesAdapter {
    func read() throws -> PowerPreferencesSnapshot
    /// `restoring` permits a saved special timer value outside the new-input
    /// range. It never permits a new key, source, or mode.
    func write(_ value: PowerPreferenceValue, restoring: Bool) throws
}

enum PowerPreferenceWritePhase: String, Codable {
    case applying, restoring, rollingBack
}

struct PendingPowerPreferenceWrite: Codable, Equatable {
    let previousValue: Int
    let targetValue: Int
    let phase: PowerPreferenceWritePhase
}

struct PowerPreferenceBackup: Codable, Equatable {
    let original: PowerPreferenceValue
    /// The last value confirmed by readback, never an unconfirmed intention.
    var lastWritten: Int
    /// Optional so existing array-based backups remain readable. Either side
    /// may be observed after an interrupted write; a third value is external.
    var pendingWrite: PendingPowerPreferenceWrite? = nil

    func owns(_ value: Int) -> Bool {
        if let pendingWrite {
            return value == pendingWrite.previousValue || value == pendingWrite.targetValue
        }
        return value == lastWritten
    }
}

protocol PowerPreferencesStore {
    func load() throws -> [PowerPreferenceBackup]
    func save(_ records: [PowerPreferenceBackup]) throws
}

final class JSONPowerPreferencesStore: PowerPreferencesStore {
    let url: URL
    init(directory: URL? = nil) throws {
        let folder = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SleepSeal", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent("power-preferences.json")
    }
    func load() throws -> [PowerPreferenceBackup] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PowerPreferencesFailure("The saved power settings are not a regular file.")
        }
        return try JSONDecoder().decode([PowerPreferenceBackup].self, from: Data(contentsOf: url))
    }
    func save(_ records: [PowerPreferenceBackup]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct PowerPreferencesFailure: Error, LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

struct PowerApplyResult {
    let actual: PowerPreferencesSnapshot
    let errors: [String]
    let didRollback: Bool
    var succeeded: Bool { errors.isEmpty }
}

/// The owner serializes calls with guard transitions. Persistent timer/mode
/// backups are independent of the transient sleep recovery record.
final class PowerPreferencesManager {
    private let adapter: PowerPreferencesAdapter
    private let store: PowerPreferencesStore
    private(set) var backups: [PowerPreferenceBackup]

    init(adapter: PowerPreferencesAdapter, store: PowerPreferencesStore) throws {
        self.adapter = adapter
        self.store = store
        self.backups = try store.load()
    }

    func read() throws -> PowerPreferencesSnapshot { try adapter.read() }

    func apply(_ edits: [PowerPreferenceEdit], guardPending: Bool) throws -> PowerApplyResult {
        let actual = try adapter.read()
        var seen = Set<String>()
        for edit in edits {
            guard seen.insert(edit.original.id).inserted else {
                throw PowerPreferencesFailure("A power setting was edited more than once.")
            }
            guard actual.matching(edit.original) == edit.original else {
                throw PowerPreferencesFailure("Power settings changed outside SleepSeal. Refresh before applying changes.")
            }
            try validate(edit.original.replacingValue(edit.target), snapshot: actual, restoring: false,
                         guardPending: guardPending)
        }
        return try write(edits.filter { $0.target != $0.original.value }, initial: actual, restoring: false)
    }

    func restoreOriginals(guardPending: Bool) throws -> PowerApplyResult {
        let actual = try adapter.read()
        var edits: [PowerPreferenceEdit] = []
        var conflicts: [String] = []
        for backup in backups {
            guard let current = actual.matching(backup.original) else {
                conflicts.append("\(backup.original.id): this setting is no longer available."); continue
            }
            if current.value == backup.original.value { continue }
            guard backup.owns(current.value) else {
                conflicts.append("\(backup.original.id): changed outside SleepSeal; left unchanged."); continue
            }
            do {
                try validate(backup.original, snapshot: actual, restoring: true, guardPending: guardPending)
                edits.append(PowerPreferenceEdit(original: current, target: backup.original.value))
            } catch { conflicts.append(String(describing: error)) }
        }
        let result = try write(edits, initial: actual, restoring: true)
        // Keep the original baseline for fields that have an external conflict.
        // Successful restores can be forgotten; a later edit starts a new baseline.
        if result.succeeded {
            let retained = backups.filter { backup in
                result.actual.matching(backup.original)?.value != backup.original.value
            }
            try store.save(retained)
            backups = retained
        }
        return PowerApplyResult(actual: result.actual, errors: conflicts + result.errors,
                                didRollback: result.didRollback)
    }

    private func validate(_ value: PowerPreferenceValue, snapshot: PowerPreferencesSnapshot,
                          restoring: Bool, guardPending: Bool) throws {
        guard snapshot.matching(value) != nil else {
            throw PowerPreferencesFailure("This power setting is unavailable on this Mac.")
        }
        if value.key.isTimer {
            let maximum = restoring ? Int(Int32.max) : 1440
            guard value.value >= 0, value.value <= maximum else {
                throw PowerPreferencesFailure("Choose Never or a time from 1 to 1440 minutes.")
            }
        } else {
            guard !guardPending else {
                throw PowerPreferencesFailure("Restore the current protection cycle before editing the power mode.")
            }
            let allowed = restoring ? (value.key == .lowPowerMode ? [0, 1] : [0, 1, 2])
                : (snapshot.supportedEnergyModes[value.source] ?? [])
            guard allowed.contains(value.value), value.key != .lowPowerMode || value.value <= 1 else {
                throw PowerPreferencesFailure("This power mode is unavailable on this Mac.")
            }
        }
    }

    private func write(_ edits: [PowerPreferenceEdit], initial: PowerPreferencesSnapshot,
                       restoring: Bool) throws -> PowerApplyResult {
        guard !edits.isEmpty else { return PowerApplyResult(actual: initial, errors: [], didRollback: false) }
        let previousBackups = backups
        var attempted: [PowerPreferenceEdit] = []
        do {
            for edit in edits {
                // Compare immediately before every write, including each source.
                let current = try adapter.read()
                guard current.matching(edit.original) == edit.original else {
                    throw PowerPreferencesFailure("Power settings changed while applying. Refresh and try again.")
                }
                try prepare(edit, phase: restoring ? .restoring : .applying)
                attempted.append(edit)
                try adapter.write(edit.original.replacingValue(edit.target), restoring: restoring)
                let verified = try adapter.read()
                guard verified.matching(edit.original)?.value == edit.target else {
                    throw PowerPreferencesFailure("macOS did not accept \(edit.original.id).")
                }
                try commit(edit.original.replacingValue(edit.target))
            }
            return PowerApplyResult(actual: try adapter.read(), errors: [], didRollback: false)
        } catch {
            var errors = [String(describing: error)]
            var rollbackComplete = true
            for edit in attempted.reversed() {
                do {
                    let observed = try adapter.read().matching(edit.original)
                    if observed == edit.original {
                        try commit(edit.original)
                        continue
                    }
                    guard observed?.value == edit.target else {
                        rollbackComplete = false
                        errors.append("\(edit.original.id): changed outside SleepSeal; rollback left it unchanged.")
                        continue
                    }
                    let rollback = PowerPreferenceEdit(original: edit.original.replacingValue(edit.target),
                                                       target: edit.original.value)
                    try prepare(rollback, phase: .rollingBack)
                    try adapter.write(edit.original, restoring: true)
                    guard try adapter.read().matching(edit.original) == edit.original else {
                        throw PowerPreferencesFailure("Rollback verification failed for \(edit.original.id).")
                    }
                    try commit(edit.original)
                } catch {
                    rollbackComplete = false
                    errors.append("Rollback: \(error)")
                }
            }
            if rollbackComplete {
                do { try store.save(previousBackups); backups = previousBackups }
                catch { errors.append("Could not save rollback result: \(error)") }
            }
            return PowerApplyResult(actual: try adapter.read(), errors: errors, didRollback: !attempted.isEmpty)
        }
    }

    private func prepare(_ edit: PowerPreferenceEdit, phase: PowerPreferenceWritePhase) throws {
        var next = backups
        let index: Int
        if let existing = next.firstIndex(where: { $0.original.id == edit.original.id }) {
            index = existing
        } else {
            next.append(PowerPreferenceBackup(original: edit.original, lastWritten: edit.original.value))
            index = next.count - 1
        }
        next[index].pendingWrite = PendingPowerPreferenceWrite(previousValue: edit.original.value,
            targetValue: edit.target, phase: phase)
        // Preserve the confirmed value until both the OS write and readback
        // finish. Rollback uses the same protocol as an ordinary write.
        try store.save(next)
        backups = next
    }

    private func commit(_ value: PowerPreferenceValue) throws {
        guard let index = backups.firstIndex(where: { $0.original.id == value.id }) else { return }
        var next = backups
        next[index].lastWritten = value.value
        next[index].pendingWrite = nil
        try store.save(next)
        backups = next
    }
}
