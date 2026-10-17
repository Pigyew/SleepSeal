import Foundation
import CoreFoundation

enum HotCorner: String, Codable, CaseIterable {
    case topLeft = "tl"
    case topRight = "tr"
    case bottomLeft = "bl"
    case bottomRight = "br"

    var actionKey: String { "wvous-\(rawValue)-corner" }
    var modifierKey: String { "wvous-\(rawValue)-modifier" }
}

struct HotCornerConfiguration: Codable, Equatable {
    let corner: HotCorner
    let action: Int?
    let modifier: Int
    let actionLabel: String

    var isDisplaySleep: Bool { action == 10 }
    var isLockScreen: Bool { action == 13 }
    var isActive: Bool { (action ?? 0) > 1 }

    init(corner: HotCorner, action: Int?, modifier: Int = 0) {
        self.corner = corner
        self.action = action
        self.modifier = modifier
        self.actionLabel = Self.label(for: action)
    }

    private static func label(for action: Int?) -> String {
        switch action {
        case nil: return "Not configured"
        case 0, 1: return "No action"
        case 2: return "Mission Control"
        case 3: return "Application Windows"
        case 4: return "Desktop"
        case 5: return "Start Screen Saver"
        case 6: return "Disable Screen Saver"
        case 7: return "Dashboard (legacy)"
        case 10: return "Put Display to Sleep"
        case 11: return "Launchpad"
        case 12: return "Notification Center"
        case 13: return "Lock Screen"
        case 14: return "Quick Note"
        case .some(let value): return "Unknown action (\(value))"
        }
    }
}

enum HotCorners {
    /// Request every corner and its modifier for each diagnostic snapshot.
    /// Actual sleep handling uses OS events, independently of preference-cache timing.
    /// CopyAppValue reads the effective user/managed Dock preference value.
    static func read() -> [HotCornerConfiguration] {
        read { key in
            CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString)
        }
    }

    /// Injectable provider for tests; production uses the read-only CF API above.
    static func read(valueForKey: (String) -> Any?) -> [HotCornerConfiguration] {
        var values: [String: Any] = [:]
        for corner in HotCorner.allCases {
            values[corner.actionKey] = valueForKey(corner.actionKey)
            values[corner.modifierKey] = valueForKey(corner.modifierKey)
        }
        return parse(values)
    }

    static func parse(_ values: [String: Any]) -> [HotCornerConfiguration] {
        HotCorner.allCases.map { corner in
            HotCornerConfiguration(
                corner: corner,
                action: nonnegativeInteger(values[corner.actionKey]),
                modifier: nonnegativeInteger(values[corner.modifierKey]) ?? 0
            )
        }
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        // A malformed string or a boolean must never become a sleep action.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue), integer >= 0 else {
            return nil
        }
        return integer
    }
}
