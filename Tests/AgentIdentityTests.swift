import Foundation
import Security
import Darwin

#if AGENT_IDENTITY_TESTS
// This suite links the real IPC implementation without runtime power adapters.
// User-agent installation is deliberately unreachable in these tests.
struct GuardFailure: Error { let message: String; init(_ message: String) { self.message = message } }
func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 2) throws -> (status: Int32, output: String) {
    fatalError("Identity tests must never install or modify a LaunchAgent")
}
#endif

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(description: message) }
}
private final class Probe: NSObject, SleepSealControlProtocol {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func showDashboard(withReply reply: @escaping (Bool) -> Void) {
        lock.lock(); calls += 1; lock.unlock()
        reply(true)
    }
}
private final class ProbeDelegate: NSObject, NSXPCListenerDelegate {
    let probe = Probe()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard AgentIdentity.accepts(euid: connection.effectiveUserIdentifier, ownUID: getuid(), hasRequirement: true) else { return false }
        connection.exportedInterface = NSXPCInterface(with: SleepSealControlProtocol.self)
        connection.exportedObject = probe
        connection.resume()
        return true
    }
}

@main
struct AgentIdentityTests {
    static let wrongBuildRequirement = "cdhash H\"0000000000000000000000000000000000000000\""
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("same-user requirement is mandatory", identityPolicy),
            ("running code satisfies its designated build requirement", designatedRequirement),
            ("a different build hash is rejected", wrongBuild),
            ("matching anonymous XPC code can exchange a request", matchingXPC),
            ("listener rejects an unmatched XPC build", rejectingListener),
            ("client rejects replies from an unmatched XPC service", rejectingClient)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) identity tests passed using anonymous XPC only; no LaunchAgents were changed.")
    }
    static func identityPolicy() throws {
        try expect(AgentIdentity.accepts(euid: 501, ownUID: 501, hasRequirement: true), "Matching same-user request refused")
        try expect(!AgentIdentity.accepts(euid: 502, ownUID: 501, hasRequirement: true), "Another user was accepted")
        try expect(!AgentIdentity.accepts(euid: 0, ownUID: 501, hasRequirement: true), "Root UID bypassed same-user condition")
        try expect(!AgentIdentity.accepts(euid: 501, ownUID: 501, hasRequirement: false), "Missing code requirement was accepted")
    }
    static func codeAndRequirement(_ text: String) throws -> (SecCode, SecRequirement) {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw CheckFailure(description: "Cannot read current signed test code") }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { throw CheckFailure(description: "Cannot parse designated requirement") }
        return (code, requirement)
    }
    static func designatedRequirement() throws {
        let text = try AgentIdentity.requirement()
        let (code, requirement) = try codeAndRequirement(text)
        try expect(!text.isEmpty && SecCodeCheckValidity(code, [], requirement) == errSecSuccess, "Current build requirement did not verify its own code")
        try expect(text.contains("cdhash") || text.contains("anchor"), "Requirement only checks an identifier")
    }
    static func wrongBuild() throws {
        let (code, requirement) = try codeAndRequirement(wrongBuildRequirement)
        try expect(SecCodeCheckValidity(code, [], requirement) != errSecSuccess, "Wrong build requirement matched")
    }
    static func matchingXPC() throws {
        let current = try AgentIdentity.requirement()
        let result = try exchange(listenerRequirement: current, clientRequirement: current)
        try expect(result.replied && result.calls == 1, "Matching anonymous XPC request failed")
    }
    static func rejectingListener() throws {
        let result = try exchange(listenerRequirement: wrongBuildRequirement, clientRequirement: AgentIdentity.requirement())
        try expect(!result.replied && result.calls == 0, "Unmatched listener requirement allowed a control request")
    }
    static func rejectingClient() throws {
        let result = try exchange(listenerRequirement: AgentIdentity.requirement(), clientRequirement: wrongBuildRequirement)
        // Foundation validates inbound messages. A matching client can send a
        // request, but a reply from a service outside its requirement is refused.
        try expect(!result.replied, "Client accepted an unmatched service reply")
    }
    static func exchange(listenerRequirement: String, clientRequirement: String) throws -> (replied: Bool, calls: Int) {
        let listener = NSXPCListener.anonymous()
        let delegate = ProbeDelegate()
        listener.setConnectionCodeSigningRequirement(listenerRequirement)
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.setCodeSigningRequirement(clientRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: SleepSealControlProtocol.self)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var replied = false
        connection.invalidationHandler = { semaphore.signal() }
        connection.resume()
        defer { connection.invalidate(); listener.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in semaphore.signal() }) as? SleepSealControlProtocol else {
            throw CheckFailure(description: "Missing XPC proxy")
        }
        proxy.showDashboard { success in lock.lock(); replied = success; lock.unlock(); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 3)
        lock.lock(); let success = replied; lock.unlock()
        return (success, delegate.probe.callCount)
    }
}
