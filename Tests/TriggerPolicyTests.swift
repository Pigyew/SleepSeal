import Foundation

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(description: message) }
}
private let display = HotCornerScreen(id: "primary", x: 0, y: 0, width: 1440, height: 900)
private let middle = HotCornerPoint(x: 500, y: 400)
private let topRight = HotCornerPoint(x: 1439, y: 899)
private func cornerSettings(_ corner: HotCorner = .topRight, modifier: Int = 0) -> [HotCornerConfiguration] {
    HotCorner.allCases.map { HotCornerConfiguration(corner: $0, action: $0 == corner ? 10 : 1,
                                                   modifier: $0 == corner ? modifier : 0) }
}

@main
struct TriggerPolicyTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("all sixteen custom trigger combinations", allCombinations),
            ("all mode protects unknown and unselected sources", allWays),
            ("corner subset follows configured corner choices", cornerSubset),
            ("manual request needs acceptance and actual sleep", manualRequest),
            ("manual intent expires and failed requests stay connected", manualFailureAndExpiry),
            ("stale manual completion cannot replace a new request", staleManualCompletion),
            ("closed-display operation is not lid sleep", lidNeedsActualSystemSleep),
            ("open and stale lid evidence cannot match", lidExpiry),
            ("idle proposals can be canceled and expire", idleProposal),
            ("display idle uses its real enabled timer", displayIdleTimer),
            ("hot corner entry works on negative-coordinate displays", negativeDisplayCorner),
            ("all four corner geometries are supported", allCornerGeometries),
            ("parked pointer does not renew an old entry", parkedPointer),
            ("required modifiers must match on entry", modifierMatching),
            ("changed system configuration invalidates prior evidence", changedConfiguration),
            ("wake clears old source evidence", wakeInvalidation),
            ("first use stays disabled and migration retains all ways", firstUseAndMigration),
            ("configuration saves atomically and round trips all selections", configurationPersistence),
            ("unsupported or damaged configuration is preserved", configurationFailures),
            ("language resolution follows explicit selection", languageResolution)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) trigger/configuration tests passed without hardware changes.")
    }

    static func allCombinations() throws {
        let cases = ProtectionTrigger.allCases
        let origins: [SleepOrigin] = [.manual, .lid, .hotCorner(.topRight), .idle]
        for mask in 0..<16 {
            let selected = Set(cases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            let policy = TriggerPolicy(mode: .custom, sources: selected)
            for (index, origin) in origins.enumerated() {
                let decision = policy.decision(for: origin)
                try expect(decision.shouldProtect == selected.contains(cases[index]), "Wrong selection for combination \(mask), \(cases[index])")
            }
            try expect(!policy.decision(for: .unknown).shouldProtect && policy.decision(for: .unknown).reason == .unknownSource,
                       "Unknown origin must keep its connection for combination \(mask)")
        }
    }

    static func allWays() throws {
        let policy = TriggerPolicy(mode: .all, sources: [], selectedCorners: [])
        for origin: SleepOrigin in [.manual, .lid, .hotCorner(.bottomLeft), .idle, .unknown] {
            try expect(policy.decision(for: origin) == TriggerDecision(shouldProtect: true, reason: .allWays),
                       "All ways must cover every actual sleep")
        }
    }

    static func cornerSubset() throws {
        let policy = TriggerPolicy(mode: .custom, sources: [.hotCorner], selectedCorners: [.bottomLeft, .topRight])
        try expect(policy.decision(for: .hotCorner(.bottomLeft)).shouldProtect, "Selected bottom-left corner skipped")
        try expect(policy.decision(for: .hotCorner(.topRight)).shouldProtect, "Selected top-right corner skipped")
        try expect(policy.decision(for: .hotCorner(.topLeft)).reason == .unselectedCorner, "Unselected corner protected")
        try expect(!policy.decision(for: .manual).shouldProtect, "Unselected source protected")
        let followSystem = TriggerPolicy(mode: .custom, sources: [.hotCorner], selectedCorners: nil)
        try expect(HotCorner.allCases.allSatisfy { followSystem.decision(for: .hotCorner($0)).shouldProtect }, "Follow configured corners omitted a position")
    }

    static func manualRequest() throws {
        let c = SleepOriginClassifier()
        let token = c.recordManualRequest(at: 10)
        try expect(c.classify(.system, at: 10, lidIsClosed: false) == .unknown, "Unaccepted request qualified")
        c.completeManualRequest(token, accepted: true)
        try expect(c.classify(.system, at: 10.2, lidIsClosed: false) == .manual, "Accepted actual sleep was not manual")
        try expect(c.classify(.display, at: 10.3, lidIsClosed: false) == .manual, "Display event lost the same manual intent")
    }

    static func manualFailureAndExpiry() throws {
        let c = SleepOriginClassifier()
        let rejected = c.recordManualRequest(at: 1)
        c.completeManualRequest(rejected, accepted: false)
        try expect(c.classify(.system, at: 2, lidIsClosed: false) == .unknown, "Failed request qualified")
        let accepted = c.recordManualRequest(at: 10)
        c.completeManualRequest(accepted, accepted: true)
        try expect(c.classify(.system, at: 18.1, lidIsClosed: false) == .unknown, "Old intent qualified a later unrelated sleep")
        try expect(c.classify(.system, at: 9, lidIsClosed: false) == .unknown, "Backward clock qualified an intent")
    }

    static func staleManualCompletion() throws {
        let c = SleepOriginClassifier()
        let old = c.recordManualRequest(at: 1)
        let new = c.recordManualRequest(at: 2)
        c.completeManualRequest(old, accepted: true)
        try expect(c.classify(.system, at: 2.1, lidIsClosed: false) == .unknown, "Old completion accepted a newer request")
        c.completeManualRequest(new, accepted: true)
        c.completeManualRequest(old, accepted: false)
        try expect(c.classify(.system, at: 2.2, lidIsClosed: false) == .manual, "Old failure erased a newer accepted request")
    }

    static func lidNeedsActualSystemSleep() throws {
        let c = SleepOriginClassifier()
        c.recordLidChange(closed: false, at: 0)
        c.recordLidChange(closed: true, at: 1)
        try expect(c.classify(.display, at: 1.1, lidIsClosed: true) == .unknown,
                   "Closed-display work was treated as lid sleep on a display event")
        try expect(c.classify(.system, at: 1.2, lidIsClosed: true) == .lid, "Actual system sleep after close was not lid sleep")
        c.recordLidChange(closed: true, at: 30)
        try expect(c.classify(.system, at: 30, lidIsClosed: true) == .unknown,
                   "Repeated closed-state polling refreshed stale lid evidence")
    }

    static func lidExpiry() throws {
        let c = SleepOriginClassifier()
        c.recordLidChange(closed: true, at: 1)
        try expect(c.classify(.system, at: 5.1, lidIsClosed: true) == .unknown, "Old close matched a later sleep")
        c.recordLidChange(closed: false, at: 6)
        try expect(c.classify(.system, at: 6.1, lidIsClosed: false) == .unknown, "Open lid retained close evidence")
        c.recordLidChange(closed: true, at: 7)
        try expect(c.classify(.system, at: 7.1, lidIsClosed: false) == .unknown, "Actual open lid was ignored")
    }

    static func idleProposal() throws {
        let c = SleepOriginClassifier()
        c.recordIdleSleepProposal(at: 10)
        try expect(c.classify(.system, at: 11, lidIsClosed: false) == .idle, "Actual system idle sleep was missed")
        c.cancelIdleSleepProposal()
        try expect(c.classify(.system, at: 12, lidIsClosed: false) == .unknown, "Canceled proposal matched actual sleep")
        c.recordIdleSleepProposal(at: 20)
        try expect(c.classify(.system, at: 50.1, lidIsClosed: false) == .unknown, "Stale proposal matched")
        try expect(c.classify(.display, at: 21, lidIsClosed: false) == .unknown, "System proposal alone classified a display event")
    }

    static func displayIdleTimer() throws {
        let c = SleepOriginClassifier()
        try expect(c.classify(.display, at: 20, lidIsClosed: false, inputIdleSeconds: 59.9, displaySleepMinutes: 1) == .unknown,
                   "Display before its configured timer was called idle")
        try expect(c.classify(.display, at: 20, lidIsClosed: false, inputIdleSeconds: 60, displaySleepMinutes: 1) == .idle,
                   "Display meeting its configured timer was missed")
        for timer: Int? in [nil, 0, -1] {
            try expect(c.classify(.display, at: 20, lidIsClosed: false, inputIdleSeconds: 1000, displaySleepMinutes: timer) == .unknown,
                       "Missing, never or invalid timer qualified")
        }
        for seconds in [Double.nan, Double.infinity, -1] {
            try expect(c.classify(.display, at: 20, lidIsClosed: false, inputIdleSeconds: seconds, displaySleepMinutes: 1) == .unknown,
                       "Invalid idle measurement qualified")
        }
    }

    static func negativeDisplayCorner() throws {
        let screen = HotCornerScreen(id: "left", x: -1920, y: -400, width: 1920, height: 1080)
        let tracker = HotCornerEntryTracker()
        let config = cornerSettings(.topLeft)
        tracker.observe(point: middle, screens: [display, screen], modifiers: 0, configurations: config, at: 0)
        tracker.observe(point: HotCornerPoint(x: -1920, y: 679), screens: [display, screen], modifiers: 0, configurations: config, at: 1)
        let entry = tracker.recentEntry(at: 1.1)
        try expect(entry?.corner == .topLeft && entry?.screenID == "left", "Negative-coordinate display corner was missed")
        let c = SleepOriginClassifier(corners: tracker)
        try expect(c.classify(.display, at: 1.2, lidIsClosed: false) == .hotCorner(.topLeft), "Actual display event lost corner association")
        try expect(c.classify(.system, at: 1.2, lidIsClosed: false) == .unknown, "Corner alone attributed unrelated system sleep")
    }

    static func allCornerGeometries() throws {
        let screen = HotCornerScreen(id: "below", x: -200, y: -800, width: 1000, height: 700)
        let points: [(HotCorner, HotCornerPoint)] = [
            (.topLeft, HotCornerPoint(x: -200, y: -101)), (.topRight, HotCornerPoint(x: 799, y: -101)),
            (.bottomLeft, HotCornerPoint(x: -200, y: -800)), (.bottomRight, HotCornerPoint(x: 799, y: -800))
        ]
        for (corner, point) in points { try expect(screen.corner(at: point) == corner, "Wrong \(corner) geometry") }
        try expect(screen.corner(at: HotCornerPoint(x: 0, y: -500)) == nil, "Interior point called a corner")
        try expect(screen.corner(at: HotCornerPoint(x: 800, y: -800)) == nil, "Point outside display accepted")
    }

    static func parkedPointer() throws {
        let tracker = HotCornerEntryTracker()
        let config = cornerSettings()
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: config, at: 0)
        try expect(tracker.recentEntry(at: 0) == nil, "Startup in a corner counted as a new entry")
        tracker.observe(point: middle, screens: [display], modifiers: 0, configurations: config, at: 1)
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: config, at: 2)
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: config, at: 20)
        try expect(tracker.recentEntry(at: 20) == nil, "Parked pointer refreshed expired evidence")
        tracker.observe(point: middle, screens: [display], modifiers: 0, configurations: config, at: 21)
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: config, at: 22)
        try expect(tracker.recentEntry(at: 22)?.enteredAt == 22, "A fresh entry did not qualify")
    }

    static func modifierMatching() throws {
        let tracker = HotCornerEntryTracker()
        let shift = 1 << 17
        let control = 1 << 18
        let config = cornerSettings(.topRight, modifier: control)
        tracker.observe(point: middle, screens: [display], modifiers: 0, configurations: config, at: 0)
        tracker.observe(point: topRight, screens: [display], modifiers: shift, configurations: config, at: 1)
        try expect(tracker.recentEntry(at: 1) == nil, "Wrong modifier qualified")
        tracker.observe(point: topRight, screens: [display], modifiers: control, configurations: config, at: 1.1)
        try expect(tracker.recentEntry(at: 1.1) == nil, "Changing modifiers while parked counted as an entry")
        tracker.observe(point: middle, screens: [display], modifiers: control, configurations: config, at: 2)
        tracker.observe(point: topRight, screens: [display], modifiers: control | (1 << 16), configurations: config, at: 3)
        try expect(tracker.recentEntry(at: 3)?.corner == .topRight, "Required control modifier with Caps Lock was missed")
        let unsupported = cornerSettings(.topRight, modifier: 1 << 25)
        tracker.observe(point: middle, screens: [display], modifiers: 0, configurations: unsupported, at: 4)
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: unsupported, at: 5)
        try expect(tracker.recentEntry(at: 5) == nil, "Unknown future modifier was silently dropped")
    }

    static func changedConfiguration() throws {
        let tracker = HotCornerEntryTracker()
        let old = cornerSettings()
        tracker.observe(point: middle, screens: [display], modifiers: 0, configurations: old, at: 0)
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: old, at: 1)
        let revision = tracker.configurationRevision
        tracker.updateConfigurations(cornerSettings(.bottomLeft))
        try expect(tracker.configurationRevision != revision && tracker.recentEntry(at: 1.1) == nil,
                   "Changed preferences retained previous evidence")
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: old, at: 1.2)
        try expect(tracker.recentEntry(at: 1.2) == nil, "Configuration update while parked fabricated a new entry")
        tracker.observe(point: middle, screens: [display], modifiers: 0, configurations: old, at: 2)
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: old, at: 3)
        try expect(tracker.recentEntry(at: 3) != nil, "New entry under current preferences failed")
        let lock = HotCorner.allCases.map { HotCornerConfiguration(corner: $0, action: 13) }
        tracker.observe(point: middle, screens: [display], modifiers: 0, configurations: lock, at: 4)
        tracker.observe(point: topRight, screens: [display], modifiers: 0, configurations: lock, at: 5)
        try expect(tracker.recentEntry(at: 5) == nil, "Lock-screen corner was treated as display sleep")
    }

    static func wakeInvalidation() throws {
        let c = SleepOriginClassifier()
        let token = c.recordManualRequest(at: 1)
        c.completeManualRequest(token, accepted: true)
        c.recordLidChange(closed: true, at: 1)
        c.recordIdleSleepProposal(at: 1)
        c.didWake()
        try expect(c.classify(.system, at: 1.1, lidIsClosed: true) == .unknown, "Wake retained previous-cycle evidence")
    }

    static func firstUseAndMigration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SleepSeal-config-\(UUID().uuidString)/configuration.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppConfigurationStore(fileURL: url)
        let firstUse = try store.load()
        try expect(!firstUse.protectionEnabled && !firstUse.onboardingCompleted && firstUse.triggerPolicy.mode == .all,
                   "First use did not wait for confirmation with All preselected")
        try expect(!FileManager.default.fileExists(atPath: url.path), "Reading first use wrote defaults")
        let migrated = try store.load(existingInstallation: true)
        try expect(migrated.protectionEnabled && migrated.triggerPolicy.mode == .all, "Upgrade changed existing all-sleep behavior")
    }

    static func configurationPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SleepSeal-config-\(UUID().uuidString)/configuration.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppConfigurationStore(fileURL: url)
        var configuration = AppConfiguration(existingInstallation: true, triggerPolicy: TriggerPolicy(mode: .custom, sources: [.manual, .idle], selectedCorners: [.topLeft]), language: .simplifiedChinese, launchAtLogin: false)
        try store.save(configuration)
        let restored = try store.load()
        try expect(restored == configuration, "Configuration did not round-trip")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Configuration was not private")
        configuration.protectionPaused = true
        try store.save(configuration)
        let changed = try store.load()
        try expect(changed == configuration, "Atomic replacement retained the old value")
        try expect(!configuration.protectionEnabled, "Pause did not disable subsequent protection")
    }

    static func configurationFailures() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SleepSeal-config-\(UUID().uuidString)/configuration.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppConfigurationStore(fileURL: url)
        var configuration = AppConfiguration()
        configuration.schemaVersion = 2
        do { try store.save(configuration); throw CheckFailure(description: "Future version was overwritten") }
        catch AppConfigurationError.unsupportedVersion(2) { }
        try expect(!FileManager.default.fileExists(atPath: url.path), "Invalid save wrote a file")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("{broken-json".utf8)
        try damaged.write(to: url)
        do { _ = try store.load(); throw CheckFailure(description: "Damaged configuration was silently replaced") }
        catch is DecodingError { }
        let retained = try Data(contentsOf: url)
        try expect(retained == damaged, "Load modified a damaged configuration")
    }

    static func languageResolution() throws {
        try expect(AppLanguage.system.resolvedLanguage(preferredLanguages: ["zh-Hans-SG"]) == .simplifiedChinese, "Chinese system language not followed")
        try expect(AppLanguage.system.resolvedLanguage(preferredLanguages: ["en-US", "zh-Hans"]) == .english, "Wrong preferred-language order")
        try expect(AppLanguage.english.resolvedLanguage(preferredLanguages: ["zh-Hans"]) == .english, "Explicit English was overridden")
        try expect(AppLanguage.simplifiedChinese.resolvedLanguage(preferredLanguages: []) == .simplifiedChinese, "Explicit Chinese was overridden")
    }
}
