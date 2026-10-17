import Foundation

enum SleepOrigin: Codable, Equatable {
    case manual
    case lid
    case hotCorner(HotCorner)
    case idle
    case unknown

    var trigger: ProtectionTrigger? {
        switch self {
        case .manual: return .manual
        case .lid: return .lid
        case .hotCorner: return .hotCorner
        case .idle: return .idle
        case .unknown: return nil
        }
    }

    /// Display idle and hot corners are correlated with public system events.
    var isAutomaticallyIdentified: Bool {
        switch self {
        case .hotCorner, .idle: return true
        default: return false
        }
    }
}

enum ProtectionTrigger: String, Codable, CaseIterable {
    case manual, lid, hotCorner, idle
}

enum ProtectionMode: String, Codable {
    case all, custom
}

enum TriggerDecisionReason: String, Codable {
    case allWays, selectedSource, unselectedSource, unknownSource, unselectedCorner
}

struct TriggerDecision: Equatable {
    let shouldProtect: Bool
    let reason: TriggerDecisionReason
}

struct TriggerPolicy: Codable, Equatable {
    var mode: ProtectionMode
    var sources: Set<ProtectionTrigger>
    /// nil follows all configured display-sleep corners; an empty set selects none.
    var selectedCorners: Set<HotCorner>?

    init(mode: ProtectionMode = .all, sources: Set<ProtectionTrigger> = Set(ProtectionTrigger.allCases),
         selectedCorners: Set<HotCorner>? = nil) {
        self.mode = mode
        self.sources = sources
        self.selectedCorners = selectedCorners
    }

    func decision(for origin: SleepOrigin) -> TriggerDecision {
        if mode == .all { return TriggerDecision(shouldProtect: true, reason: .allWays) }
        guard let trigger = origin.trigger else {
            return TriggerDecision(shouldProtect: false, reason: .unknownSource)
        }
        guard sources.contains(trigger) else {
            return TriggerDecision(shouldProtect: false, reason: .unselectedSource)
        }
        if case .hotCorner(let corner) = origin, let selected = selectedCorners, !selected.contains(corner) {
            return TriggerDecision(shouldProtect: false, reason: .unselectedCorner)
        }
        return TriggerDecision(shouldProtect: true, reason: .selectedSource)
    }
}

/// All times are monotonic uptime values supplied by the event adapter. This
/// classifier never changes hardware and never reacts to a sleep proposal alone.
/// Call classify only after an actual display or system sleep notification.
final class SleepOriginClassifier {
    private struct ManualIntent {
        let id: UUID
        let requestedAt: TimeInterval
        var accepted: Bool
    }
    private var manualIntent: ManualIntent?
    private var lidClosed = false
    private var lidClosedAt: TimeInterval?
    private var idleProposedAt: TimeInterval?
    let corners: HotCornerEntryTracker
    let manualWindow: TimeInterval
    let lidWindow: TimeInterval
    let idleProposalWindow: TimeInterval

    init(corners: HotCornerEntryTracker = HotCornerEntryTracker(), manualWindow: TimeInterval = 8,
         lidWindow: TimeInterval = 4, idleProposalWindow: TimeInterval = 30) {
        self.corners = corners
        self.manualWindow = manualWindow
        self.lidWindow = lidWindow
        self.idleProposalWindow = idleProposalWindow
    }

    @discardableResult
    func recordManualRequest(at time: TimeInterval) -> UUID {
        let id = UUID()
        manualIntent = ManualIntent(id: id, requestedAt: time, accepted: false)
        return id
    }

    func completeManualRequest(_ id: UUID, accepted: Bool) {
        guard manualIntent?.id == id else { return }
        if accepted { manualIntent?.accepted = true } else { manualIntent = nil }
    }

    /// Only a newly observed close is lid evidence. A machine already operating
    /// in closed-display mode must not attribute later idle sleep to its lid.
    func recordLidChange(closed: Bool, at time: TimeInterval) {
        if closed && !lidClosed { lidClosedAt = time }
        if !closed { lidClosedAt = nil }
        lidClosed = closed
    }

    func recordIdleSleepProposal(at time: TimeInterval) { idleProposedAt = time }
    func cancelIdleSleepProposal() { idleProposedAt = nil }

    func classify(_ source: SleepSource, at time: TimeInterval, lidIsClosed: Bool,
                  inputIdleSeconds: TimeInterval = 0, displaySleepMinutes: Int? = nil) -> SleepOrigin {
        if let intent = manualIntent, intent.accepted,
           isRecent(intent.requestedAt, at: time, within: manualWindow) { return .manual }
        if source == .system, lidIsClosed, lidClosed,
           let closedAt = lidClosedAt, isRecent(closedAt, at: time, within: lidWindow) { return .lid }
        if source == .display, let entry = corners.recentEntry(at: time) { return .hotCorner(entry.corner) }
        if source == .system, let proposedAt = idleProposedAt,
           isRecent(proposedAt, at: time, within: idleProposalWindow) { return .idle }
        if source == .display, let minutes = displaySleepMinutes, minutes > 0,
           inputIdleSeconds.isFinite, inputIdleSeconds >= 0,
           // Public APIs do not provide a display-sleep cause. Match the real
           // configured timer conservatively; lock/screensaver do not call here.
           inputIdleSeconds >= Double(minutes) * 60 { return .idle }
        return .unknown
    }

    /// Any real wake starts a new evidence window. A wake does not restore radios.
    func didWake() {
        manualIntent = nil
        idleProposedAt = nil
        lidClosedAt = nil
        corners.clearEvidence()
    }

    private func isRecent(_ event: TimeInterval, at time: TimeInterval, within window: TimeInterval) -> Bool {
        event.isFinite && time.isFinite && time >= event && time - event <= window
    }
}
