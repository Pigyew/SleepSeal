import Foundation

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(description: message) }
}
@main struct ErrorPresentationTests {
    static func main() throws {
        let cases: [(String, String, String)] = [
            ("Saved app settings need repair; new protection is paused.", "You can still restore connections", "仍可"),
            ("Saved power settings need repair; new protection and power edits are paused.", "saved files have been preserved", "原文件已保留"),
            ("Some apps have not quit. Handle their save prompts or cancel, then retry sleep. / 部分应用尚未退出，请处理保存提示或取消后再重试睡眠。", "Some apps have not quit", "部分应用尚未退出"),
            ("Sleep preparation cancelled / 睡眠准备已取消", "Sleep preparation was cancelled", "睡眠准备已取消"),
            ("Cannot read active power assertions / 无法读取当前电源断言 (-1)", "could not check which apps", "无法检查哪些应用"),
            ("无法切换蓝牙；请检查 SleepSeal 的蓝牙权限", "Bluetooth", "蓝牙"),
            ("蓝牙控制接口不可用", "Bluetooth", "蓝牙"),
            ("sessionNotVerified", "Unlock this Mac", "解锁"),
            ("unsupportedVersion(2)", "newer SleepSeal version", "更新版本"),
            ("dataCorrupted(Swift.DecodingError.Context)", "saved settings or recovery record", "恢复记录"),
            ("Power settings changed outside SleepSeal. Refresh before applying changes.", "Refresh the values", "刷新当前值"),
            ("Choose Never or a time from 1 to 1440 minutes.", "1 to 1440", "1–1440"),
            ("Restore the current protection cycle before editing the power mode.", "Screen and sleep timers", "关屏和睡眠时间"),
            ("This power setting is unavailable on this Mac.", "selected power source", "所选供电方式"),
            ("此设备没有可识别的低电量模式设置，停止操作", "does not report support", "未报告支持"),
            ("Reinstall the power helper with the SleepSeal installer / 请使用 SleepSeal 安装器修复电源工具", "not authorized", "尚未授权"),
            ("sudo: a password is required", "Run the SleepSeal installer", "运行 SleepSeal 安装器"),
            ("Protection needs Bluetooth and power-helper permission; connections kept / 保护需要蓝牙与电源工具权限，本次保持连接", "Connections were kept", "保持连接"),
            ("没有找到 Wi-Fi 接口", "Wi-Fi could not", "Wi-Fi"),
            ("恢复电源设置后状态不符：-b powermode", "could not be restored", "未能恢复"),
            ("Rollback verification failed for -c.sleep.", "could not be rolled back", "未能回滚"),
            ("-b.sleep: changed outside SleepSeal; rollback left it unchanged.", "newer value was kept", "保留较新的值"),
            ("Power setting failed / 电源设置失败：macOS rejected the requested power setting", "did not accept", "未接受"),
            ("Invalid fixed power-control arguments.", "invalid and was not applied", "无效"),
            ("Operation budget exhausted / 操作已超时", "timed out", "超时"),
            ("macOS rejected sleep request / macOS 拒绝睡眠请求 (-1)", "connections unchanged", "保持连接"),
            ("Sleep event registration failed / 睡眠监听注册失败", "listen for macOS sleep events", "监听"),
            ("Background service unavailable. Reopen the installed app to retry.", "background service is unavailable", "后台服务不可用"),
            ("The code signature requirement failed.", "verify this build", "验证当前版本"),
            ("SleepSeal is already running / SleepSeal 已在运行", "menu bar icon", "菜单栏图标"),
            ("Migration cleanup needs retry / 迁移清理需要重试", "remaining components were kept", "剩余文件已保留")
        ]
        for (raw, english, chinese) in cases {
            let en = RuntimeErrorPresentation.message(raw, languageCode: "en")
            let zh = RuntimeErrorPresentation.message(raw, languageCode: "zh-Hans")
            try expect(en.contains(english), "Missing English presentation for \(raw)")
            try expect(zh.contains(chinese), "Missing Chinese presentation for \(raw)")
            try expect(!en.contains("Technical details:"), "App-owned failure fell through to untranslated detail: \(raw)")
        }
        let english = RuntimeErrorPresentation.message("无法切换蓝牙", languageCode: "en-US")
        try expect(!english.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) }, "English app failure contains Chinese text")
        let aggregate = RuntimeErrorPresentation.message("无法切换蓝牙；恢复电源设置后状态不符：-b powermode", languageCode: "en")
        try expect(aggregate.contains("Bluetooth") && aggregate.contains("could not be restored"), "Aggregate failure lost a material recovery error")
        let unknown = RuntimeErrorPresentation.message("OS error " + String(repeating: "x", count: 5000) + "\u{1b}[31m", languageCode: "zh-Hans")
        try expect(unknown.hasPrefix("macOS 未能完成请求") && unknown.contains("技术详情："), "Unknown OS failure has no localized explanation")
        try expect(unknown.count < 800 && !unknown.contains("\u{1b}"), "Unknown details were unbounded or retained control sequences")
        print("PASS: \(cases.count) bilingual error categories, aggregate failures, explicit languages and bounded OS details; no hardware used.")
    }
}
