import Foundation

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

@main struct BlockingAppsCancellationTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("a fresh token permits queued work", freshToken),
            ("cancellation invalidates every previously queued token", cancelQueued),
            ("new work can acquire a token after cancellation", newEpoch),
            ("repeated cancellations never revive old tokens", repeatedCancellation),
            ("cancellation becomes visible across threads", crossThreadVisibility),
            ("concurrent cancellation increments are not lost", concurrentCancellation)
        ]
        for (name, test) in tests { try test(); print("PASS: \(name)") }
        print("\(tests.count) cancellation tests passed; no native application adapters were used.")
    }
    static func freshToken() throws {
        let cancellation = BlockingAppsCancellation()
        let token = cancellation.token()
        try expect(!cancellation.isCancelled(token), "Fresh work was canceled")
        try expect(cancellation.token() == token, "Reading a token changed its epoch")
    }
    static func cancelQueued() throws {
        let cancellation = BlockingAppsCancellation()
        let tokens = (0..<10).map { _ in cancellation.token() }
        cancellation.cancel()
        try expect(tokens.allSatisfy { cancellation.isCancelled($0) }, "A queued operation retained permission")
    }
    static func newEpoch() throws {
        let cancellation = BlockingAppsCancellation()
        let original = cancellation.token()
        cancellation.cancel()
        let current = cancellation.token()
        try expect(current != original && !cancellation.isCancelled(current), "New work inherited stale cancellation")
        try expect(cancellation.isCancelled(original), "Acquiring new work revived an old token")
    }
    static func repeatedCancellation() throws {
        let cancellation = BlockingAppsCancellation()
        let original = cancellation.token()
        for _ in 0..<100 { cancellation.cancel() }
        try expect(cancellation.isCancelled(original), "Repeated cancel revived an old epoch")
        try expect(cancellation.token() == original + 100, "Cancellation epoch did not advance once per event")
    }
    static func crossThreadVisibility() throws {
        let cancellation = BlockingAppsCancellation()
        let token = cancellation.token()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { cancellation.cancel(); completed.signal() }
        try expect(completed.wait(timeout: .now() + 2) == .success, "Background cancellation did not complete")
        try expect(cancellation.isCancelled(token), "Main-side cancellation read a stale epoch")
    }
    static func concurrentCancellation() throws {
        let cancellation = BlockingAppsCancellation()
        let initial = cancellation.token()
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<1000 {
                    let old = cancellation.token()
                    _ = cancellation.isCancelled(old)
                    cancellation.cancel()
                }
                group.leave()
            }
        }
        try expect(group.wait(timeout: .now() + 5) == .success, "Concurrent cancellation deadlocked")
        try expect(cancellation.token() == initial + 8000, "Concurrent updates lost cancellation epochs")
        try expect(cancellation.isCancelled(initial), "Concurrent readers revived stale work")
    }
}
