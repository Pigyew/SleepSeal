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

/// AppKit's global screen coordinates have their origin at the lower left of
/// the primary display. Secondary displays can have negative coordinates.
struct HotCornerPoint: Equatable {
    let x: Double
    let y: Double
}

struct HotCornerScreen: Equatable {
    let id: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func corner(at point: HotCornerPoint, tolerance: Double = 2) -> HotCorner? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              point.x.isFinite, point.y.isFinite, width > 0, height > 0,
              point.x >= x, point.x < x + width, point.y >= y, point.y < y + height else { return nil }
        let left = point.x <= x + tolerance
        let right = point.x >= x + width - 1 - tolerance
        let bottom = point.y <= y + tolerance
        let top = point.y >= y + height - 1 - tolerance
        if left && top { return .topLeft }
        if right && top { return .topRight }
        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        return nil
    }
}

struct HotCornerEntry: Equatable {
    let corner: HotCorner
    let screenID: String
    let enteredAt: TimeInterval
    let modifiers: Int
    let configurationRevision: UInt64
}

/// Retains only the most recent entry, never a pointer trail. Calling observe
/// repeatedly while a pointer is parked cannot refresh its timestamp. A changed
/// system configuration invalidates evidence from the previous configuration.
final class HotCornerEntryTracker {
    private struct Location: Hashable {
        let corner: HotCorner
        let screenID: String
    }

    private var configurations: [HotCornerConfiguration] = []
    private var occupied: Set<Location> = []
    private var observedPointer = false
    private var entry: HotCornerEntry?
    private(set) var configurationRevision: UInt64 = 0
    let correlationWindow: TimeInterval

    init(correlationWindow: TimeInterval = 2) {
        self.correlationWindow = correlationWindow
    }

    func updateConfigurations(_ values: [HotCornerConfiguration]) {
        let stable = HotCorner.allCases.compactMap { corner in values.first { $0.corner == corner } }
        guard stable != configurations else { return }
        configurations = stable
        configurationRevision &+= 1
        entry = nil
    }

    func observe(point: HotCornerPoint, screens: [HotCornerScreen], modifiers: Int,
                 configurations: [HotCornerConfiguration], at time: TimeInterval) {
        updateConfigurations(configurations)
        let locations = Set(screens.compactMap { screen -> Location? in
            guard let corner = screen.corner(at: point) else { return nil }
            return Location(corner: corner, screenID: screen.id)
        })
        defer { occupied = locations; observedPointer = true }
        // Startup with the pointer already in a corner is not a new entry.
        guard observedPointer, time.isFinite else { return }
        let entered = locations.subtracting(occupied).sorted {
            if $0.screenID != $1.screenID { return $0.screenID < $1.screenID }
            return $0.corner.rawValue < $1.corner.rawValue
        }
        let keyboardMask = 0x1e0000 // Shift, Control, Option, Command only.
        for location in entered {
            guard let config = self.configurations.first(where: { $0.corner == location.corner }),
                  config.isDisplaySleep, (config.modifier & ~keyboardMask) == 0,
                  (modifiers & keyboardMask) == (config.modifier & keyboardMask) else { continue }
            entry = HotCornerEntry(corner: location.corner, screenID: location.screenID,
                                   enteredAt: time, modifiers: modifiers & keyboardMask,
                                   configurationRevision: configurationRevision)
            return
        }
    }

    func recentEntry(at time: TimeInterval) -> HotCornerEntry? {
        guard let entry = entry, time.isFinite, time >= entry.enteredAt,
              time - entry.enteredAt <= correlationWindow,
              entry.configurationRevision == configurationRevision else { return nil }
        return entry
    }

    func clearEvidence() { entry = nil }
}
