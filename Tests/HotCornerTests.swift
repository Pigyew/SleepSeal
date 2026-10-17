import Foundation

private struct HotCornerTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HotCornerTestFailure(description: message) }
}

@main
struct HotCornerTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("unset corners stay inactive", unsetCorners),
            ("every corner can contain display sleep", displaySleepAtEachCorner),
            ("all eight preference keys are read", allKeysRead),
            ("changed and disabled settings are read afresh", preferencesChange),
            ("modifier combinations are preserved", modifiersPreserved),
            ("lock and quick note remain distinct from display sleep", distinctActions),
            ("disabled actions never count as active", disabledActions),
            ("malformed actions cannot enable sleep", malformedActions),
            ("malformed modifiers default to none", malformedModifiers),
            ("unknown actions are preserved without matching sleep", unknownActions),
            ("configuration encodes its labels and round trips", codableRoundTrip)
        ]
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
        print("All \(tests.count) hot-corner tests passed; no system settings were read or changed.")
    }

    static func unsetCorners() throws {
        let entries = HotCorners.parse([:])
        try expect(entries.map(\.corner) == HotCorner.allCases, "Need a stable record for each of four corners")
        try expect(entries.allSatisfy { $0.action == nil && $0.modifier == 0 && !$0.isActive && !$0.isDisplaySleep }, "Missing preferences should be inactive")
    }

    static func displaySleepAtEachCorner() throws {
        for corner in HotCorner.allCases {
            let entries = HotCorners.parse([corner.actionKey: 10])
            let matches = entries.filter(\.isDisplaySleep)
            try expect(matches.count == 1 && matches.first?.corner == corner, "Display sleep must work at \(corner.rawValue)")
            try expect(matches.first?.actionLabel == "Put Display to Sleep", "Sleep should be labelled precisely")
        }
    }

    static func allKeysRead() throws {
        var keys: [String] = []
        let entries = HotCorners.read { key in
            keys.append(key)
            return nil
        }
        let expected = HotCorner.allCases.flatMap { [$0.actionKey, $0.modifierKey] }
        try expect(keys == expected, "Read must include action and modifier for every corner")
        try expect(entries.count == 4, "Absent values must not drop a corner")
    }

    static func preferencesChange() throws {
        var preferences: [String: Any] = [HotCorner.topRight.actionKey: 10]
        let first = HotCorners.read { preferences[$0] }
        preferences = [HotCorner.bottomLeft.actionKey: 10, HotCorner.bottomLeft.modifierKey: 131072]
        let second = HotCorners.read { preferences[$0] }
        preferences = [:]
        let third = HotCorners.read { preferences[$0] }
        try expect(first.filter(\.isDisplaySleep).map(\.corner) == [.topRight], "Initial provider result")
        try expect(second.filter(\.isDisplaySleep).map(\.corner) == [.bottomLeft], "Moved hot corner must be detected without restarting")
        try expect(second.first { $0.corner == .bottomLeft }?.modifier == 131072, "New modifier must be detected")
        try expect(third.allSatisfy { !$0.isActive }, "Disabling hot corners must remove all matches")
    }

    static func modifiersPreserved() throws {
        let mask = 1048576 | 524288 | 262144 | 131072
        let entries = HotCorners.parse([
            "wvous-tl-corner": NSNumber(value: 10), "wvous-tl-modifier": NSNumber(value: mask),
            "wvous-tr-corner": 13, "wvous-tr-modifier": 524288,
            "wvous-bl-corner": 5, "wvous-bl-modifier": 262144,
            "wvous-br-corner": 14, "wvous-br-modifier": 131072
        ])
        try expect(entries.map(\.modifier) == [mask, 524288, 262144, 131072], "Keep exact modifier combinations for all corners")
    }

    static func distinctActions() throws {
        let entries = HotCorners.parse(["wvous-tr-corner": 10, "wvous-tl-corner": 13, "wvous-br-corner": 14])
        try expect(entries.filter(\.isDisplaySleep).map(\.corner) == [.topRight], "Quick Note and lock are not display sleep")
        try expect(entries.filter(\.isLockScreen).map(\.corner) == [.topLeft], "Lock action must remain identifiable")
        try expect(entries.first { $0.corner == .bottomRight }?.actionLabel == "Quick Note", "Quick Note label")
    }

    static func disabledActions() throws {
        for value in [0, 1] {
            let entries = HotCorners.parse(["wvous-tr-corner": value])
            try expect(entries.allSatisfy { !$0.isActive && !$0.isDisplaySleep && !$0.isLockScreen }, "No-action code \(value) must remain inactive")
        }
    }

    static func malformedActions() throws {
        for value: Any in ["10", true, false, -10, 10.5, Double.infinity, Double.nan, NSNull(), [10]] {
            let entry = HotCorners.parse(["wvous-tl-corner": value])[0]
            try expect(entry.action == nil && !entry.isDisplaySleep, "Malformed action \(value) must not match")
        }
    }

    static func malformedModifiers() throws {
        for value: Any in ["131072", true, -1, 0.5, Double.infinity, NSNull()] {
            let entry = HotCorners.parse(["wvous-tl-corner": 10, "wvous-tl-modifier": value])[0]
            try expect(entry.modifier == 0 && entry.isDisplaySleep, "Malformed modifiers should not alter the valid action")
        }
    }

    static func unknownActions() throws {
        let entry = HotCorners.parse(["wvous-tl-corner": 999])[0]
        try expect(entry.action == 999 && !entry.isDisplaySleep && !entry.isLockScreen, "Future actions must not be misclassified")
        try expect(entry.actionLabel == "Unknown action (999)", "Retain useful diagnostics for future action codes")
    }

    static func codableRoundTrip() throws {
        let source = HotCorners.parse(["wvous-tr-corner": 10, "wvous-tr-modifier": 131072])
        let data = try JSONEncoder().encode(source)
        let restored = try JSONDecoder().decode([HotCornerConfiguration].self, from: data)
        let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        try expect(restored == source, "Configuration must round-trip through diagnostics JSON")
        try expect(raw?[1]["actionLabel"] as? String == "Put Display to Sleep", "JSON must include the descriptive action label")
    }
}
