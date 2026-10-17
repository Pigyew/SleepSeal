import Foundation

/// Presentation boundary for legacy adapter errors and current typed failures.
/// App-owned failures have complete English/Chinese messages. Unrecognized OS
/// failures keep a bounded technical detail after a localized explanation.
enum RuntimeErrorPresentation {
    private struct Rule {
        let id: String
        let phrases: [String]
        let english: String
        let chinese: String
    }

    private static let rules: [Rule] = [
        Rule(id: "rollback", phrases: ["rollback verification failed", "could not save rollback result", "rollback:"],
             english: "Some changes could not be rolled back. Check the current values before retrying; the recovery record has been kept.",
             chinese: "部分更改未能回滚。请先检查当前实际值再重试；恢复记录已保留。"),
        Rule(id: "rollbackExternal", phrases: ["rollback left it unchanged"],
             english: "A setting changed outside SleepSeal during rollback. Its newer value was kept. Refresh to review it.",
             chinese: "回滚时发现某项设置已被其他程序更改，已保留较新的值。请刷新后检查。"),
        Rule(id: "powerConflict", phrases: ["power settings changed outside sleepseal", "power settings changed while applying"],
             english: "Power settings changed outside SleepSeal. Refresh the values, review your edits, and apply them again.",
             chinese: "系统电源设置已被其他程序更改。请刷新当前值，检查修改后重新应用。"),
        Rule(id: "modePending", phrases: ["restore the current protection cycle before editing the power mode"],
             english: "Restore the current sleep protection cycle before changing the daily power mode. Screen and sleep timers can still be edited.",
             chinese: "请先恢复本轮睡眠保护，再修改日常电源模式。关屏和睡眠时间仍可编辑。"),
        Rule(id: "timer", phrases: ["choose never or a time from 1 to 1440", "invalid timer"],
             english: "Choose Never, or enter a whole number from 1 to 1440 minutes.",
             chinese: "请选择“永不”，或输入 1–1440 之间的整数分钟。"),
        Rule(id: "modeUnavailable", phrases: ["this power mode is unavailable", "没有可识别的低电量模式"],
             english: "This Mac does not report support for the requested power mode. No unsupported mode was applied.",
             chinese: "这台 Mac 未报告支持所选电源模式，未应用不受支持的模式。"),
        Rule(id: "powerUnavailable", phrases: ["this power setting is unavailable"],
             english: "This power setting is unavailable for the selected power source on this Mac.",
             chinese: "这台 Mac 的所选供电方式不支持此电源设置。"),
        Rule(id: "permissions", phrases: ["protection needs bluetooth and power-helper permission", "保护需要蓝牙与电源工具权限"],
             english: "Allow Bluetooth access and install the power helper before enabling protection. Connections were kept for this sleep.",
             chinese: "请先允许蓝牙权限并安装电源工具，再启用保护。本次睡眠已保持连接。"),
        Rule(id: "bluetooth", phrases: ["蓝牙控制接口不可用", "无法切换蓝牙", "无法读取蓝牙状态", "bluetooth control unavailable", "bluetooth permission"],
             english: "Bluetooth could not be controlled. Allow SleepSeal in System Settings → Privacy & Security → Bluetooth, then retry.",
             chinese: "无法控制蓝牙。请前往“系统设置 → 隐私与安全性 → 蓝牙”允许 SleepSeal，然后重试。"),
        Rule(id: "helper", phrases: ["reinstall the power helper", "power helper is unavailable", "power-helper authorization", "power helper authorization", "power-helper permission denied", "installed sleepseal authorization rule", "requesting account does not match", "installation authorization record", "privileged installation path", "privileged tool is not a regular file", "请使用 sleepseal 安装器修复电源工具", "电源工具不可用", "a password is required", "not allowed to execute", "a terminal is required"],
             english: "The power helper is missing or this macOS account is not authorized. Run the SleepSeal installer while logged in to this account, then reopen the app.",
             chinese: "电源工具缺失，或当前 macOS 账户尚未授权。请登录此账户运行 SleepSeal 安装器，再重新打开应用。"),
        Rule(id: "session", phrases: ["sessionnotverified", "verified, unlocked console session", "restore the recovery record before uninstalling", "请先恢复记录再卸载"],
             english: "Unlock this Mac with the account running SleepSeal, then retry recovery. The original settings remain saved.",
             chinese: "请使用运行 SleepSeal 的账户解锁这台 Mac，再重试恢复。原始设置仍已保存。"),
        Rule(id: "configurationVersion", phrases: ["unsupportedversion", "requires a newer sleepseal version"],
             english: "These saved settings require a newer SleepSeal version. Install a newer version; the saved file was kept.",
             chinese: "已保存的设置需要更新版本的 SleepSeal。请安装较新版本；原文件已保留。"),
        Rule(id: "configurationRead", phrases: ["datacorrupted", "keynotfound", "typemismatch", "valuenotfound", "not a regular file", "configuration could not be loaded", "recovery record could not be loaded"],
             english: "SleepSeal could not read its saved settings or recovery record. The file has been kept. Use Checks & recovery before changing protection.",
             chinese: "SleepSeal 无法读取已保存的设置或恢复记录。原文件已保留。请先在“检查与恢复”中处理，再修改保护状态。"),
        Rule(id: "configurationSave", phrases: ["configuration could not be saved", "could not save settings", "nsfilewritenopermission", "nsfilewriteoutofspace"],
             english: "SleepSeal could not save the change. Check available storage and access to your user settings folder, then retry.",
             chinese: "SleepSeal 无法保存更改。请检查剩余空间和用户设置文件夹的访问权限，然后重试。"),
        Rule(id: "wifi", phrases: ["没有找到 wi-fi 接口", "无法读取 wi-fi 状态", "找不到原来的 wi-fi 接口", "wi-fi 切换后状态不符"],
             english: "Wi-Fi could not be read or changed. Check the Wi-Fi adapter and retry. Any pending original settings remain saved.",
             chinese: "无法读取或更改 Wi-Fi 状态。请检查 Wi-Fi 适配器后重试；待恢复的原始设置仍已保存。"),
        Rule(id: "powerRead", phrases: ["cannot read power settings", "无法读取电源设置"],
             english: "macOS power settings could not be read. Refresh and retry; SleepSeal will not replace unreadable settings with defaults.",
             chinese: "无法读取 macOS 电源设置。请刷新后重试；SleepSeal 不会用默认值覆盖无法读取的设置。"),
        Rule(id: "restore", phrases: ["恢复电源设置后状态不符", "restoration failed", "restore verification failed"],
             english: "Some original settings could not be restored. The recovery record has been kept. Check the actual status and retry recovery.",
             chinese: "部分原始设置未能恢复。恢复记录已保留，请检查实际状态后重试恢复。"),
        Rule(id: "powerApply", phrases: ["power setting failed", "macos rejected the requested power setting", "macos did not accept", "电源设置失败", "电源设置未生效"],
             english: "macOS did not accept a power-setting change. Check the actual values and retry; any required recovery record has been kept.",
             chinese: "macOS 未接受某项电源设置更改。请检查实际值后重试；需要的恢复记录已保留。"),
        Rule(id: "invalid", phrases: ["invalid fixed power-control arguments", "outside the allowlist", "invalid power source", "拒绝未允许的电源参数", "无效电源来源", "invalid edit", "无效更改", "a power setting was edited more than once"],
             english: "This setting request is invalid and was not applied. Refresh the panel and choose a supported value.",
             chinese: "设置请求无效，未予应用。请刷新面板并选择支持的值。"),
        Rule(id: "timeout", phrases: ["operation budget exhausted", "command timed out", "power-setting request timed out", "sleep preparation deadline elapsed", "操作已超时", "命令超时", "睡眠准备已超时"],
             english: "The operation timed out. SleepSeal kept any pending recovery record. Check the actual status, then retry.",
             chinese: "操作超时。SleepSeal 已保留待处理的恢复记录。请检查实际状态后重试。"),
        Rule(id: "sleepRejected", phrases: ["macos rejected sleep request", "macos 拒绝睡眠请求"],
             english: "macOS rejected the sleep request. SleepSeal kept the connections unchanged. Check applications preventing sleep and retry.",
             chinese: "macOS 拒绝了睡眠请求。SleepSeal 已保持连接。请检查阻止睡眠的应用后重试。"),
        Rule(id: "displayRejected", phrases: ["display sleep request failed", "关屏请求失败"],
             english: "macOS could not turn off the display. Check applications preventing display sleep and retry.",
             chinese: "macOS 未能关闭屏幕。请检查阻止显示器睡眠的应用后重试。"),
        Rule(id: "events", phrases: ["sleep event registration failed", "睡眠监听注册失败"],
             english: "SleepSeal could not listen for macOS sleep events. Reopen the installed app or run the installer to repair the background service.",
             chinese: "SleepSeal 未能监听 macOS 睡眠事件。请重新打开已安装应用，或运行安装器修复后台服务。"),
        Rule(id: "migration", phrases: ["migration cleanup needs retry", "迁移清理需要重试"],
             english: "SleepSeal is running, but the old installation could not be fully cleaned up. The remaining components were kept. Retry from Checks & recovery or rerun the installer.",
             chinese: "SleepSeal 已在运行，但旧版组件尚未完全清理，剩余文件已保留。请在“检查与恢复”中重试，或重新运行安装器。"),
        Rule(id: "background", phrases: ["background service could not start", "background service unavailable", "reopen the installed app to repair login startup", "无法启动后台服务", "后台服务不可用", "修复登录自启"],
             english: "The background service is unavailable. Reopen the installed SleepSeal app. If it still fails, run the installer to repair it.",
             chinese: "后台服务不可用。请重新打开已安装的 SleepSeal；若仍失败，请运行安装器进行修复。"),
        Rule(id: "signature", phrases: ["cannot identify signed application", "cannot verify current build", "missing code requirement", "invalid code requirement", "code signature requirement failed", "无法验证应用签名", "无法验证当前构建", "缺少代码签名要求", "签名要求无效"],
             english: "SleepSeal could not verify this build or its background connection. Reinstall the same SleepSeal version and reopen it.",
             chinese: "SleepSeal 无法验证当前版本或后台连接。请重新安装同一版本的 SleepSeal，然后再次打开。"),
        Rule(id: "missingApp", phrases: ["application is missing", "找不到应用程序"],
             english: "The installed SleepSeal app could not be found. Run the installer again, then open SleepSeal from Applications.",
             chinese: "找不到已安装的 SleepSeal 应用。请重新运行安装器，再从“应用程序”打开 SleepSeal。"),
        Rule(id: "running", phrases: ["sleepseal is already running", "sleepseal 已在运行"],
             english: "SleepSeal is already running. Open its menu bar icon to show the control panel.",
             chinese: "SleepSeal 已在运行。请点击菜单栏图标打开控制面板。"),
        Rule(id: "uninstall", phrases: ["installed application could not be safely identified"],
             english: "The installed app could not be safely identified, so it was left in place. Run the SleepSeal installer to repair it before retrying removal.",
             chinese: "无法安全识别已安装应用，因此保留了原文件。请先运行 SleepSeal 安装器进行修复，再重试卸载。")
    ]

    static func message(_ raw: String, languageCode: String) -> String {
        let chinese = languageCode.lowercased().hasPrefix("zh")
        let normalized = raw.lowercased()
        var seen: Set<String> = []
        let messages = rules.compactMap { rule -> String? in
            guard rule.phrases.contains(where: normalized.contains), seen.insert(rule.id).inserted else { return nil }
            return chinese ? rule.chinese : rule.english
        }
        if !messages.isEmpty { return messages.joined(separator: "\n") }
        let summary = chinese
            ? "macOS 未能完成请求。请在“检查与恢复”中检查状态后重试；待恢复的原始设置仍已保存。"
            : "macOS could not complete the request. Check the status in Checks & recovery, then retry. Any pending original settings remain saved."
        let detail = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }.prefix(600))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return summary }
        return summary + (chinese ? "\n技术详情：" : "\nTechnical details: ") + detail
    }
}
