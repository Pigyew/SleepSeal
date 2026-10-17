import Foundation

@main
private struct HelperPolicyTests {
    static func main() throws {
        var checks = 0
        func accepted(_ args: [String]) {
            do { _ = try HelperPolicy.parse(args); checks += 1 }
            catch { preconditionFailure("Unexpected rejection \(args): \(error)") }
        }
        func rejected(_ args: [String]) {
            do { _ = try HelperPolicy.parse(args); preconditionFailure("Accepted invalid helper arguments: \(args)") }
            catch { checks += 1 }
        }
        for source in ["b", "c"] {
            for key in ["displaysleep", "sleep"] {
                for value in ["0", "1", "1440"] { accepted(["set", source, key, value]) }
                accepted(["restore", source, key, "2147483647"])
                rejected(["set", source, key, "1441"])
                rejected(["restore", source, key, "2147483648"])
            }
            for key in ["powernap", "tcpkeepalive", "womp", "proximitywake", "lowpowermode"] {
                accepted(["set", source, key, "0"])
                accepted(["restore", source, key, "1"])
                rejected(["set", source, key, "2"])
                rejected(["restore", source, key, "2147483647"])
            }
            for value in ["0", "1", "2"] { accepted(["set", source, "powermode", value]) }
            rejected(["restore", source, "powermode", "3"])
        }
        accepted(["uninstall"])
        accepted(["check"])
        accepted(["claim"])
        accepted(["release"])
        accepted(["finalize-migration"])
        for invalid in [
            [], ["check", "501"], ["claim", "501"], ["release", "501"], ["uninstall", "/tmp"], ["finalize-migration", "501"], ["set"], ["set", "b", "sleep", "0", "extra"],
            ["set", "-b", "sleep", "1"], ["set", "a", "sleep", "1"],
            ["set", "b", "hibernatemode", "25"], ["restore", "b", "standbydelay", "1"],
            ["set", "b", "sleep", "-1"], ["set", "b", "sleep", "+1"],
            ["set", "b", "sleep", "01"], ["set", "b", "sleep", "1.0"],
            ["set", "b", "sleep", "1\n"], ["set", "b", "sleep", ""],
            ["set", "b", "sleep", "١"], ["set", "b", "sleep", "1; touch /tmp/unsafe"],
            ["set", "b", "/bin/sh", "1"], ["/bin/sh", "b", "sleep", "1"],
            ["set", "b", "sleep", "999999999999999999999999999999999"]
        ] { rejected(invalid) }
        let parsed = try HelperPolicy.parse(["set", "c", "powermode", "1"])
        precondition(parsed == .set(scope: "-c", key: "powermode", value: 1, restoring: false))
        checks += 1
        for owner: uid_t? in [nil, 501, 502] {
            precondition(HelperLeasePolicy.mayClaim(owner: owner, requester: 501) == (owner == nil || owner == 501))
            precondition(HelperLeasePolicy.mayRelease(owner: owner, requester: 501) == (owner == nil || owner == 501))
            precondition(HelperLeasePolicy.mayUninstall(owner: owner, requester: 501) == (owner != 501))
            checks += 3
        }
        print("PASS: privileged helper fixed grammar and allowlist — \(checks) checks")
    }
}
