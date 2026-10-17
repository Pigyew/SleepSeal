import AppKit
import SwiftUI

/// Invoked only by the explicit GUI self-test entry point. It never creates a
/// production controller, XPC connection, sleep request or hardware adapter.
@MainActor
enum DashboardVerification {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(outputDirectory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(description: message) }
            checks += 1
        }

        let model = DashboardModel.mock()
        var actions: [DashboardAction] = []
        model.onAction = { actions.append($0) }
        try check(!model.powerDirty, "Reading initial settings must not create power edits")
        try check(model.powerEdits()?.isEmpty == true, "Initial form must have no apply request")
        model.setDraft("0", scope: .battery, key: "displaysleep")
        try check(model.powerEdits() == [UIPowerEdit(scope: .battery, key: "displaysleep", original: 5, value: 0)], "Never must edit only the selected battery field")
        model.page = .settings
        model.page = .power
        try check(model.draft(.battery, "displaysleep") == "0", "Power drafts must survive page navigation")
        try check(model.draft(.adapter, "displaysleep") == "15", "Battery draft must not change adapter settings")
        model.setDraft("1441", scope: .battery, key: "displaysleep")
        try check(model.powerEdits() == nil, "Out-of-range newly entered timer must be rejected")
        model.applyPower()
        try check(actions.isEmpty && model.powerErrorKey == "power.validation", "Invalid power values must not dispatch a write")
        model.setDraft("1.5", scope: .battery, key: "displaysleep")
        try check(model.powerEdits() == nil, "Fractional minute inputs must be rejected")
        model.setDraft("1440", scope: .battery, key: "displaysleep")
        model.applyPower()
        try check(actions.count == 1, "A valid explicit apply must dispatch once")
        model.isBusy = true
        model.applyPower()
        try check(actions.count == 1, "Busy state must prevent duplicate dispatch")
        model.isBusy = false
        model.powerConflict = true
        model.applyPower()
        try check(actions.count == 1, "A stale form must not dispatch a write")
        model.powerConflict = false
        model.powerDrafts = [:]
        model.powerProfiles[.battery]?.values["sleep"] = 2880
        try check(model.draft(.battery, "sleep") == "2880" && model.powerEdits()?.isEmpty == true, "Unusual system originals must remain unchanged")
        model.setDraft("1", scope: .battery, key: "powermode")
        model.guardPending = true
        model.applyPower()
        try check(actions.count == 1 && model.powerErrorKey == "power.modeLocked", "Pending recovery must block an older power-mode draft")
        model.powerDrafts = [:]
        model.setDraft("60", scope: .adapter, key: "sleep")
        model.applyPower()
        try check(actions.count == 2, "Pending recovery must still permit independent persistent timers")

        for mask in 0..<16 {
            model.policy.allSources = false
            model.policy.sources = Set(UITrigger.allCases.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element })
            model.send(.savePolicy(model.policy))
            guard case let .savePolicy(policy) = actions.last else { throw Failure(description: "Policy action was not preserved") }
            try check(policy.sources.count == mask.nonzeroBitCount && !policy.allSources, "Custom trigger combination \(mask) was changed by the UI")
        }
        var resourceKeys: Set<String>?
        for code in ["en", "zh-Hans"] {
            guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: "\(code).lproj"),
                  let dictionary = NSDictionary(contentsOfFile: path) as? [String: String] else {
                throw Failure(description: "Missing or invalid \(code) localization resources")
            }
            let keys = Set(dictionary.keys)
            if let previous = resourceKeys { try check(previous == keys, "English and Chinese resource keys must match") }
            resourceKeys = keys
            try check(dictionary.values.allSatisfy { !$0.isEmpty }, "Localized messages must not be empty")
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SleepSeal GUI verification"
        defer { window.close() }
        for language in [UILanguage.english, .chinese] {
            let localized = DashboardModel.mock(language: language)
            try check(localized.text("page.overview") != "page.overview", "\(language.rawValue) resources were not bundled")
            for scheme in [ColorScheme.light, .dark] {
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                for page in DashboardPage.allCases {
                    localized.page = page
                    let hosting = NSHostingView(rootView: DashboardView(model: localized).preferredColorScheme(scheme))
                    window.contentView = hosting
                    window.setContentSize(NSSize(width: 960, height: 700))
                    window.makeKeyAndOrderFront(nil)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
                    hosting.layoutSubtreeIfNeeded()
                    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw Failure(description: "Cannot allocate owned-window snapshot") }
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Cannot encode owned-window snapshot") }
                    let name = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(page.rawValue).png"
                    try png.write(to: outputDirectory.appendingPathComponent(name))
                    if language == .english && scheme == .light && page == .overview {
                        let nodes = accessibilityNodes(window)
                        try check(nodes.contains(where: { $0.accessibilityLabel() == localized.text("action.sleep") || $0.accessibilityTitle() == localized.text("action.sleep") }), "Sleep action must expose an accessible label")
                        guard let sleepButton = nodes.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "SleepSeal.sleepNow" }) else { throw Failure(description: "The precise sleep action must be a native button") }
                        let previousHandler = localized.onAction
                        var presses = 0
                        localized.onAction = { if case .sleepNow = $0 { presses += 1 } }
                        // The action dispatch is the useful assertion. Some
                        // SwiftUI-hosted AppKit versions return false after
                        // successfully dispatching this accessibility action.
                        _ = sleepButton.accessibilityPerformPress()
                        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                        try check(presses == 1, "Accessible button activation must dispatch the mock sleep action exactly once")
                        try check(window.makeFirstResponder(sleepButton) && window.firstResponder === sleepButton, "The native sleep button must accept keyboard focus")
                        localized.onAction = previousHandler
                    }

                    try check(bitmap.pixelsWide >= 800 && bitmap.pixelsHigh >= 560, "Snapshot is unexpectedly clipped")
                }
            }
        }
        // A small-window error/conflict case exercises long bilingual recovery copy.
        let compact = DashboardModel.mock(language: .chinese, page: .power)
        compact.powerConflict = true
        compact.feedbackKey = "feedback.failed"
        compact.feedbackIsError = true
        compact.guardPending = true
        let compactView = NSHostingView(rootView: DashboardView(model: compact))
        window.contentView = compactView
        window.setContentSize(NSSize(width: 800, height: 560))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        compactView.layoutSubtreeIfNeeded()
        guard let compactBitmap = compactView.bitmapImageRepForCachingDisplay(in: compactView.bounds) else { throw Failure(description: "Cannot render compact failure view") }
        compactView.cacheDisplay(in: compactView.bounds, to: compactBitmap)
        if let data = compactBitmap.representation(using: .png, properties: [:]) {
            try data.write(to: outputDirectory.appendingPathComponent("zh-Hans-compact-conflict.png"))
        }
        try check(compactView.bounds.width >= 800, "Minimum-width layout must remain available")
        let unavailable = DashboardModel.mock(language: .english, page: .diagnostics)
        unavailable.serviceAvailable = false
        unavailable.statusKey = "guard.error"
        unavailable.permissions = [UIPermission(id: "bluetooth", titleKey: "permission.bluetooth", detailKey: "permission.denied", ready: false, action: .openBluetoothSettings), UIPermission(id: "helper", titleKey: "permission.helper", detailKey: "permission.missing", ready: false, action: .repairInstallation)]
        let unavailableView = NSHostingView(rootView: DashboardView(model: unavailable))
        window.contentView = unavailableView
        window.setContentSize(NSSize(width: 800, height: 560))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        unavailableView.layoutSubtreeIfNeeded()
        guard let unavailableBitmap = unavailableView.bitmapImageRepForCachingDisplay(in: unavailableView.bounds) else { throw Failure(description: "Cannot render unavailable-service view") }
        unavailableView.cacheDisplay(in: unavailableView.bounds, to: unavailableBitmap)
        if let data = unavailableBitmap.representation(using: .png, properties: [:]) { try data.write(to: outputDirectory.appendingPathComponent("en-compact-permissions.png")) }
        try check(!unavailable.canUseActions, "Unavailable service must disable sleep control while keeping the dashboard usable")
        return checks
    }

    private static func accessibilityNodes(_ root: NSObject) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: AnyObject, depth: Int) {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted,
                  let accessible = object as? any NSAccessibilityProtocol else { return }
            result.append(accessible)
            for child in accessible.accessibilityChildren() ?? [] { walk(child as AnyObject, depth: depth + 1) }
            // AppKit representable controls are real child views even when
            // SwiftUI's lazy virtual accessibility tree has not initialized.
            if let view = object as? NSView { for child in view.subviews { walk(child, depth: depth + 1) } }
        }
        walk(root, depth: 0)
        return result
    }
}
