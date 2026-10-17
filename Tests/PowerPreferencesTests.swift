import Foundation

private enum TestFailure: Error { case injected }

private final class MemoryPowerStore: PowerPreferencesStore {
    var records: [PowerPreferenceBackup] = []
    var failNextSave = false
    func load() throws -> [PowerPreferenceBackup] { records }
    func save(_ records: [PowerPreferenceBackup]) throws {
        if failNextSave { failNextSave = false; throw TestFailure.injected }
        self.records = records
    }
}

/// Only test fixtures are written. Abrupt child exit bypasses the manager's
/// catch/rollback path so restarting exercises the actual persisted journal.
private final class InterruptingPowerStore: PowerPreferencesStore {
    let disk: JSONPowerPreferencesStore
    var afterSave: (([PowerPreferenceBackup], [PowerPreferenceBackup]) -> Void)?
    init(directory: URL) throws { disk = try JSONPowerPreferencesStore(directory: directory) }
    func load() throws -> [PowerPreferenceBackup] { try disk.load() }
    func save(_ records: [PowerPreferenceBackup]) throws {
        let previous = try disk.load()
        try disk.save(records)
        afterSave?(previous, records)
    }
}

private final class MockPowerAdapter: PowerPreferencesAdapter {
    var snapshot: PowerPreferencesSnapshot
    var writes: [(PowerPreferenceValue, Bool)] = []
    var failWriteNumbers = Set<Int>()
    var acceptWithoutChanging = false
    var afterWrite: ((MockPowerAdapter, Int) -> Void)?
    var reads = 0
    var beforeRead: ((MockPowerAdapter, Int) -> Void)?
    init(_ snapshot: PowerPreferencesSnapshot) { self.snapshot = snapshot }
    func read() throws -> PowerPreferencesSnapshot {
        reads += 1; beforeRead?(self, reads)
        return PowerPreferencesSnapshot(values: snapshot.values, supportedEnergyModes: snapshot.supportedEnergyModes)
    }
    func write(_ value: PowerPreferenceValue, restoring: Bool) throws {
        writes.append((value, restoring))
        let number = writes.count
        if failWriteNumbers.contains(number) { throw TestFailure.injected }
        if !acceptWithoutChanging { replace(value) }
        afterWrite?(self, number)
    }
    func replace(_ value: PowerPreferenceValue) {
        snapshot.values.removeAll { $0.id == value.id }
        snapshot.values.append(value)
    }
}

@main
private struct PowerPreferencesTests {
    static let interruptionStatus: Int32 = 86
    static func interruptedChild(directory: URL, scenario: String) throws {
        let parts = scenario.split(separator: ":").map(String.init)
        let operation = parts[0], boundary = parts[1]
        let battery = PowerPreferenceValue(source: .battery, key: .displaySleep, value: 5)
        let adapterValue = PowerPreferenceValue(source: .adapter, key: .displaySleep, value: 0)
        let adapter = MockPowerAdapter(PowerPreferencesSnapshot(values: [battery, adapterValue]))
        let store = try InterruptingPowerStore(directory: directory)
        let observedURL = directory.appendingPathComponent("observed.json")
        func saveObserved() throws { try JSONEncoder().encode(adapter.snapshot).write(to: observedURL, options: .atomic) }
        try saveObserved()
        adapter.afterWrite = { _, _ in try! saveObserved() }
        let manager = try PowerPreferencesManager(adapter: adapter, store: store)
        if operation != "initial" {
            _ = try manager.apply([PowerPreferenceEdit(original: battery, target: 30)], guardPending: false)
        }
        let phase: PowerPreferenceWritePhase = operation == "restore" ? .restoring
            : operation == "rollback" ? .rollingBack : .applying
        store.afterSave = { previous, current in
            let old = previous.first { $0.original.id == battery.id }
            let new = current.first { $0.original.id == battery.id }
            if boundary == "prepared", new?.pendingWrite?.phase == phase {
                exit(interruptionStatus)
            }
            if boundary == "committed", old?.pendingWrite?.phase == phase, new?.pendingWrite == nil {
                exit(interruptionStatus)
            }
        }
        adapter.afterWrite = { _, _ in
            try! saveObserved()
            if boundary == "written",
               try! store.load().first(where: { $0.original.id == battery.id })?.pendingWrite?.phase == phase {
                exit(interruptionStatus)
            }
        }
        switch operation {
        case "initial":
            _ = try manager.apply([PowerPreferenceEdit(original: battery, target: 30)], guardPending: false)
        case "repeat":
            _ = try manager.apply([PowerPreferenceEdit(original: battery.replacingValue(30), target: 60)], guardPending: false)
        case "restore":
            _ = try manager.restoreOriginals(guardPending: false)
        case "rollback":
            adapter.failWriteNumbers = [adapter.writes.count + 2]
            _ = try manager.apply([
                PowerPreferenceEdit(original: battery.replacingValue(30), target: 60),
                PowerPreferenceEdit(original: adapterValue, target: 90)
            ], guardPending: false)
        default: preconditionFailure("Unknown interruption scenario")
        }
        preconditionFailure("Interruption checkpoint was not reached: \(scenario)")
    }

    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--interrupt-journal" {
            try interruptedChild(directory: URL(fileURLWithPath: CommandLine.arguments[2]),
                                 scenario: CommandLine.arguments[3])
            return
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); checks += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected rejection: \(name)") }
            catch { checks += 1 }
        }
        func value(_ source: PowerSource, _ key: PowerSettingKey, _ n: Int) -> PowerPreferenceValue {
            PowerPreferenceValue(source: source, key: key, value: n)
        }
        let sample = """
        Battery Power:
         displaysleep 5
         sleep 10
         powermode 0
         lowpowermode 1
         hibernatemode 3
        AC Power:
         displaysleep 0
         sleep 2147483647
         powermode 2
        UPS Power:
         displaysleep 1
        """
        let parsed = PowerPreferencesSnapshot.parse(custom: sample)
        check(parsed.values.count == 6, "Both sources and only allowed persistent settings")
        check(parsed.energyMode(source: .battery)?.key == .powerMode, "Modern key takes precedence")
        check(parsed.value(source: .adapter, key: .displaySleep)?.value == 0, "Never is preserved")
        check(parsed.value(source: .adapter, key: .systemSleep)?.value == Int(Int32.max), "Special existing value preserved")
        check(parsed.supportedEnergyModes[.battery] == [0, 1], "Do not infer high power merely from powermode")
        check(parsed.supportedEnergyModes[.adapter] == [0, 1, 2], "Existing high mode proves support")
        let cap = "Capabilities for Battery Power:\n highpowermode\nCapabilities for AC Power:\n displaysleep"
        check(PowerPreferencesSnapshot.parse(custom: sample, capabilities: cap).supportedEnergyModes[.battery] == [0, 1, 2], "Explicit high power capability")
        let legacy = PowerPreferencesSnapshot.parse(custom: "Battery Power:\n lowpowermode 1\n sleep -1\n displaysleep 2147483648")
        check(legacy.values.count == 1 && legacy.energyMode(source: .battery)?.key == .lowPowerMode, "Legacy mode and invalid raw values")

        let adapter = MockPowerAdapter(parsed)
        let store = MemoryPowerStore()
        let manager = try PowerPreferencesManager(adapter: adapter, store: store)
        check(adapter.writes.isEmpty && store.records.isEmpty, "Opening reads no defaults into macOS")
        let originalBattery = value(.battery, .displaySleep, 5)
        let originalAdapter = value(.adapter, .displaySleep, 0)
        let applied = try manager.apply([
            PowerPreferenceEdit(original: originalBattery, target: 0),
            PowerPreferenceEdit(original: originalAdapter, target: 45)
        ], guardPending: false)
        check(applied.succeeded && adapter.writes.count == 2, "Independent battery and AC writes")
        check(applied.actual.matching(originalBattery)?.value == 0 && applied.actual.matching(originalAdapter)?.value == 45, "Separate actual values read back")
        check(store.records.count == 2 && store.records.first?.original == originalBattery, "Durable first original saved separately")
        _ = try manager.apply([PowerPreferenceEdit(original: originalBattery.replacingValue(0), target: 60)], guardPending: false)
        check(store.records.first?.original == originalBattery && store.records.first?.lastWritten == 60, "Repeated edit retains first baseline")
        check(store.records.allSatisfy { $0.pendingWrite == nil }, "Successful readback commits every write intention")

        rejects("Reject out-of-range new timer") {
            _ = try manager.apply([PowerPreferenceEdit(original: originalBattery.replacingValue(60), target: 1441)], guardPending: false)
        }
        rejects("Reject negative timer") {
            _ = try manager.apply([PowerPreferenceEdit(original: originalBattery.replacingValue(60), target: -1)], guardPending: false)
        }
        rejects("Reject unsupported high power") {
            _ = try manager.apply([PowerPreferenceEdit(original: value(.battery, .powerMode, 0), target: 2)], guardPending: false)
        }
        rejects("Guard pending makes mode read-only") {
            _ = try manager.apply([PowerPreferenceEdit(original: value(.battery, .powerMode, 0), target: 1)], guardPending: true)
        }
        let pendingTimer = try manager.apply([PowerPreferenceEdit(original: originalBattery.replacingValue(60), target: 90)], guardPending: true)
        check(pendingTimer.succeeded, "Persistent timers remain editable during protection")
        let writeCount = adapter.writes.count
        rejects("Reject stale external changes") {
            _ = try manager.apply([PowerPreferenceEdit(original: originalBattery, target: 100)], guardPending: false)
        }
        check(adapter.writes.count == writeCount, "Conflict does not write any field")
        rejects("Reject duplicate edit") {
            let edit = PowerPreferenceEdit(original: originalBattery.replacingValue(90), target: 100)
            _ = try manager.apply([edit, edit], guardPending: false)
        }

        adapter.replace(originalAdapter.replacingValue(120))
        let restore = try manager.restoreOriginals(guardPending: false)
        check(!restore.succeeded, "External conflict reported during restore")
        check(restore.actual.matching(originalBattery) == originalBattery, "Nonconflicting field restored")
        check(restore.actual.matching(originalAdapter)?.value == 120, "Later external setting not overwritten")
        check(store.records.count == 1 && store.records.first?.original == originalAdapter, "Conflicting backup retained")

        let rollbackAdapter = MockPowerAdapter(parsed)
        let rollbackStore = MemoryPowerStore()
        let rollbackManager = try PowerPreferencesManager(adapter: rollbackAdapter, store: rollbackStore)
        rollbackAdapter.failWriteNumbers = [2]
        let rollback = try rollbackManager.apply([
            PowerPreferenceEdit(original: originalBattery, target: 30),
            PowerPreferenceEdit(original: originalAdapter, target: 60)
        ], guardPending: false)
        check(!rollback.succeeded && rollback.didRollback, "Partial failure reported and rollback attempted")
        check(rollback.actual == parsed, "Successful preceding change rolled back")
        check(rollbackStore.records.isEmpty, "Complete rollback restores previous journal")
        check(rollbackAdapter.writes.last?.1 == true, "Rollback uses validated restore operation")

        let failedRollbackAdapter = MockPowerAdapter(parsed)
        let failedRollbackStore = MemoryPowerStore()
        let failedRollbackManager = try PowerPreferencesManager(adapter: failedRollbackAdapter, store: failedRollbackStore)
        failedRollbackAdapter.failWriteNumbers = [2, 3]
        let failedRollback = try failedRollbackManager.apply([
            PowerPreferenceEdit(original: originalBattery, target: 30),
            PowerPreferenceEdit(original: originalAdapter, target: 60)
        ], guardPending: false)
        check(!failedRollback.succeeded && failedRollback.errors.count >= 2, "Rollback failure is visible")
        check(failedRollback.actual.matching(originalBattery)?.value == 30 && !failedRollbackStore.records.isEmpty,
              "Incomplete rollback retains actual state and first-original journal")
        failedRollbackAdapter.failWriteNumbers = []
        let retry = try failedRollbackManager.restoreOriginals(guardPending: false)
        check(retry.succeeded && retry.actual == parsed && failedRollbackStore.records.isEmpty,
              "Restart/retry can finish a partially failed power transaction")

        let changingAdapter = MockPowerAdapter(parsed)
        let changingManager = try PowerPreferencesManager(adapter: changingAdapter, store: MemoryPowerStore())
        changingAdapter.beforeRead = { mock, read in
            if read == 4 { mock.replace(originalAdapter.replacingValue(77)) }
        }
        let changedMidApply = try changingManager.apply([
            PowerPreferenceEdit(original: originalBattery, target: 30),
            PowerPreferenceEdit(original: originalAdapter, target: 60)
        ], guardPending: false)
        check(!changedMidApply.succeeded && changedMidApply.actual.matching(originalBattery) == originalBattery,
              "Later-field external conflict rolls back earlier writes")
        check(changedMidApply.actual.matching(originalAdapter)?.value == 77,
              "Later-field external conflict keeps newer system value")

        let modeAdapter = MockPowerAdapter(parsed)
        let modeStore = MemoryPowerStore()
        let modeManager = try PowerPreferencesManager(adapter: modeAdapter, store: modeStore)
        _ = try modeManager.apply([
            PowerPreferenceEdit(original: value(.battery, .powerMode, 0), target: 1),
            PowerPreferenceEdit(original: originalBattery, target: 30)
        ], guardPending: false)
        let guardedRestore = try modeManager.restoreOriginals(guardPending: true)
        check(!guardedRestore.succeeded && guardedRestore.actual.energyMode(source: .battery)?.value == 1,
              "Pending transient mode prevents overlapping persistent-mode restore")
        check(guardedRestore.actual.matching(originalBattery) == originalBattery && modeStore.records.count == 1,
              "Timer restore remains independent while mode is pending")

        let specialAdapter = MockPowerAdapter(parsed)
        let specialStore = MemoryPowerStore()
        let specialManager = try PowerPreferencesManager(adapter: specialAdapter, store: specialStore)
        let special = value(.adapter, .systemSleep, Int(Int32.max))
        _ = try specialManager.apply([PowerPreferenceEdit(original: special, target: 15)], guardPending: false)
        let specialRestore = try specialManager.restoreOriginals(guardPending: false)
        check(specialRestore.succeeded && specialRestore.actual.matching(special) == special, "Restore exact special original outside input range")

        let ignoredAdapter = MockPowerAdapter(parsed)
        ignoredAdapter.acceptWithoutChanging = true
        let ignoredManager = try PowerPreferencesManager(adapter: ignoredAdapter, store: MemoryPowerStore())
        let ignored = try ignoredManager.apply([PowerPreferenceEdit(original: originalBattery, target: 30)], guardPending: false)
        check(!ignored.succeeded && ignored.actual == parsed, "Exit success without actual change fails readback verification")

        let failedStore = MemoryPowerStore()
        failedStore.failNextSave = true
        let noWrites = MockPowerAdapter(parsed)
        let failedManager = try PowerPreferencesManager(adapter: noWrites, store: failedStore)
        let journalFailure = try failedManager.apply([PowerPreferenceEdit(original: originalBattery, target: 30)], guardPending: false)
        check(!journalFailure.succeeded && noWrites.writes.isEmpty, "No system changes if original cannot be saved")

        let externalAdapter = MockPowerAdapter(parsed)
        externalAdapter.failWriteNumbers = [2]
        externalAdapter.afterWrite = { mock, number in
            if number == 1 { mock.replace(originalBattery.replacingValue(31)) }
        }
        let externalStore = MemoryPowerStore()
        let externalManager = try PowerPreferencesManager(adapter: externalAdapter, store: externalStore)
        let interrupted = try externalManager.apply([PowerPreferenceEdit(original: originalBattery, target: 30)], guardPending: false)
        check(!interrupted.succeeded && interrupted.actual.matching(originalBattery)?.value == 31, "Rollback preserves external change after failed readback")
        check(!externalStore.records.isEmpty, "Incomplete rollback retains recovery journal")

        let commitFailureAdapter = MockPowerAdapter(parsed)
        let commitFailureStore = MemoryPowerStore()
        let commitFailureManager = try PowerPreferencesManager(adapter: commitFailureAdapter, store: commitFailureStore)
        commitFailureAdapter.afterWrite = { _, number in
            if number == 1 { commitFailureStore.failNextSave = true }
        }
        let commitFailure = try commitFailureManager.apply([
            PowerPreferenceEdit(original: originalBattery, target: 30)
        ], guardPending: false)
        check(!commitFailure.succeeded && commitFailure.actual == parsed && commitFailureStore.records.isEmpty,
              "Failed confirmation save rolls the OS value back and preserves the previous journal")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("SleepSeal-power-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let disk = try JSONPowerPreferencesStore(directory: temp)
        let legacyJSON = """
        [{"original":{"source":"-b","key":"displaysleep","value":5},"lastWritten":30}]
        """
        try Data(legacyJSON.utf8).write(to: disk.url, options: .atomic)
        let legacyBackup = try disk.load()
        check(legacyBackup == [PowerPreferenceBackup(original: originalBattery, lastWritten: 30)],
              "Existing array backups decode without a pending-write field")
        try disk.save([PowerPreferenceBackup(original: originalBattery, lastWritten: 30)])
        let reloaded = try disk.load()
        check(reloaded == [PowerPreferenceBackup(original: originalBattery, lastWritten: 30)], "Backup survives process restart")
        let permissions = try FileManager.default.attributesOfItem(atPath: disk.url.path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "Durable backup is private")

        for operation in ["initial", "repeat", "restore", "rollback"] {
            for boundary in ["prepared", "written", "committed"] {
                let scenario = "\(operation):\(boundary)"
                let directory = temp.appendingPathComponent("interruption-\(operation)-\(boundary)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = ["--interrupt-journal", directory.path, scenario]
                try child.run(); child.waitUntilExit()
                check(child.terminationReason == .exit && child.terminationStatus == interruptionStatus,
                      "Child exited at the durable \(scenario) checkpoint")
                let interruptedDisk = try JSONPowerPreferencesStore(directory: directory)
                let journal = try interruptedDisk.load()
                let observed = try JSONDecoder().decode(PowerPreferencesSnapshot.self,
                    from: Data(contentsOf: directory.appendingPathComponent("observed.json")))
                let backup = journal.first { $0.original.id == originalBattery.id }!
                let expectedPhase: PowerPreferenceWritePhase = operation == "restore" ? .restoring
                    : operation == "rollback" ? .rollingBack : .applying
                if boundary == "committed" {
                    check(backup.pendingWrite == nil && backup.lastWritten == observed.matching(originalBattery)?.value,
                          "\(scenario) durably commits only a verified value")
                } else {
                    let expectedCommitted = operation == "initial" ? 5 : operation == "rollback" ? 60 : 30
                    check(backup.lastWritten == expectedCommitted && backup.pendingWrite?.phase == expectedPhase,
                          "\(scenario) retains the last confirmed value and interruption phase")
                }
                let resumedAdapter = MockPowerAdapter(observed)
                let resumed = try PowerPreferencesManager(adapter: resumedAdapter, store: interruptedDisk)
                let recovered = try resumed.restoreOriginals(guardPending: false)
                check(recovered.succeeded && recovered.actual.matching(originalBattery) == originalBattery,
                      "Restart after \(scenario) restores the first original")
                let remaining = try interruptedDisk.load()
                check(remaining.isEmpty, "Restart after \(scenario) clears completed backups")

                // A value matching neither side of a recorded write is still
                // external, even when a transaction was interrupted.
                let externalSnapshot = MockPowerAdapter(observed)
                externalSnapshot.replace(originalBattery.replacingValue(77))
                let conflictStore = MemoryPowerStore(); conflictStore.records = journal
                let conflictManager = try PowerPreferencesManager(adapter: externalSnapshot, store: conflictStore)
                let conflict = try conflictManager.restoreOriginals(guardPending: false)
                check(!conflict.succeeded && conflict.actual.matching(originalBattery)?.value == 77
                      && externalSnapshot.writes.isEmpty && !conflictStore.records.isEmpty,
                      "Restart after \(scenario) preserves a genuine external value and its backup")
            }
        }
        print("PASS: persistent power preferences, CAS, rollback and recovery — \(checks) checks")
    }
}
