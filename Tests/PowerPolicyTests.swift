import Foundation

@main struct PolicyTests {
    static func main() {
        let sample = """
        Battery Power:
         powermode 2
         lowpowermode 0
         powernap 1
         tcpkeepalive 1
         hibernatemode 3
         standby 1
        AC Power:
         lowpowermode 0
         womp 1
         proximitywake 1
        UPS Power:
         lowpowermode 1
        """
        let values = PowerPolicy.parse(sample)
        assert(values.count == 6)
        assert(values.contains(PowerValue(scope: "-b", key: "powermode", value: 2)))
        assert(!values.contains(where: { $0.key == "lowpowermode" && $0.scope == "-b" }))
        assert(values.contains(PowerValue(scope: "-c", key: "lowpowermode", value: 0)))
        assert(!values.contains(where: { ["standby", "hibernatemode"].contains($0.key) }))
        assert(PowerPolicy.desired(PowerValue(scope: "-b", key: "powermode", value: 2)) == 1)
        assert(PowerPolicy.desired(PowerValue(scope: "-b", key: "tcpkeepalive", value: 1)) == 0)
        assert(!PowerPolicy.valid(PowerValue(scope: "-a", key: "powermode", value: 1)))
        assert(!PowerPolicy.valid(PowerValue(scope: "-b", key: "hibernatemode", value: 25)))
        assert(!PowerPolicy.valid(PowerValue(scope: "-b", key: "powermode", value: 3)))
        print("PASS: 电源配置分组、高性能模式恢复、参数白名单，共 10 项检查")
    }
}
