import Foundation

protocol UninstallOperations {
    /// Back up and temporarily remove only this user's LaunchAgent. A thrown
    /// error must leave the original agent available; root work has not begun.
    func stageUserAgent() throws
    func restoreUserAgent() throws
    func removePrivilegedInstallation() throws
    /// Finalize the staged files and stop the service. This operation must be
    /// retryable if an earlier call completed only some of its cleanup steps.
    func finishUserCleanup() throws
}

enum UninstallOutcome: Equatable {
    case removed
    case cleanupRequired(String)
}

struct UninstallPrecommitFailure: Error, LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

/// Call on one serial queue, after pending hardware recovery has completed.
/// Retain this instance across retries: once privileged removal succeeds, no
/// later failure may restore startup files or resume the protection service.
final class UninstallCoordinator: @unchecked Sendable {
    // The controller dispatches work serially; the lock also protects status
    // reads and accidental concurrent retries across the UI/worker boundary.
    private let lock = NSRecursiveLock()
    private let operations: UninstallOperations
    private var userAgentStaged = false
    private var cleanupFinished = false
    private var committed = false
    var irreversibleCommitted: Bool { lock.lock(); defer { lock.unlock() }; return committed }

    init(operations: UninstallOperations) { self.operations = operations }

    func uninstall() throws -> UninstallOutcome {
        lock.lock(); defer { lock.unlock() }
        if !irreversibleCommitted {
            // A previous failed rollback must be resolved before staging again
            // or attempting another privileged removal.
            if userAgentStaged {
                try operations.restoreUserAgent()
                userAgentStaged = false
            }
            try operations.stageUserAgent()
            userAgentStaged = true
            do {
                try operations.removePrivilegedInstallation()
            } catch {
                let removalFailure = String(describing: error)
                do {
                    try operations.restoreUserAgent()
                    userAgentStaged = false
                } catch {
                    throw UninstallPrecommitFailure(description:
                        "\(removalFailure)\nCould not restore login startup: \(error)")
                }
                throw error
            }
            committed = true
        }

        if cleanupFinished { return .removed }
        do {
            try operations.finishUserCleanup()
            userAgentStaged = false
            cleanupFinished = true
            return .removed
        } catch {
            return .cleanupRequired(String(describing: error))
        }
    }
}
