# Privacy / 隐私

SleepSeal runs locally. It has no account, analytics SDK, telemetry endpoint, cloud sync, or remote dashboard. Installation does not upload diagnostics. Opening a GitHub or Apple help link uses your normal browser.

The app reads radio power state, energy settings, console lock state, lid state, configured Hot Corners, recent corner entry, input-idle duration and sleep notifications to apply your policy. Corner correlation retains only recent event context; it is not a mouse-tracking history. Sleep-blocking applications and their assertion reasons are read when diagnosing sleep behavior. The app does not need to collect browsing contents, Wi-Fi passwords, network names, or Bluetooth device addresses to implement protection.

## Local files

| Location | Purpose |
|---|---|
| `~/Library/Application Support/SleepSeal/configuration.json` | Your selected language, trigger rules, pause and startup preferences. |
| `~/Library/Application Support/SleepSeal/pending.json` | Original radio/temporary power settings and the active recovery gate. Do not delete this while recovery is pending. |
| `~/Library/Application Support/SleepSeal/power-preferences.json` | First original and last app-written persistent power settings; separate from the sleep snapshot. |
| `~/Library/Logs/SleepSeal/` | Local status, errors and rotating logs; no automatic upload. |
| `~/Library/LaunchAgents/local.sleepseal.guard.plist` | Current user's background startup configuration. |
| `/Library/Application Support/SleepSeal/authorized-users/<uid>` | Root-owned numeric authorization record for the narrow helper. |
| `/Library/Application Support/SleepSeal/protection-owner` and `protection-lock` | Root-owned numeric UID and lock that prevent overlapping protection by different accounts. |
| `/private/etc/sudoers.d/sleepseal_v2_<uid>` | Root-owned permission rule for that user; a legacy `sleepseal_<uid>` rule is retained until safe migration completes. |

Recovery/configuration files are user-private. Logs rotate at 1 MiB per file and retain three files. Uninstall preserves user diagnostics/settings files, and removes only the relevant startup/installation components after safe recovery. The separate original-power restore action controls persistent system settings.

## Sharing diagnostics

Export is initiated by you and saves locally. The report contains only the SleepSeal version, OS version, protection/pending status, Wi-Fi/Bluetooth/Low Power Mode states, and permission readiness. It excludes raw logs, interface names, blocker application names and assertion descriptions, user paths, network identifiers, account information and pending recovery snapshots.

The on-screen blocker list is separate from that export. It may show process names and text supplied by the application that created an assertion. A screenshot of the panel or a manually copied local log can therefore reveal more than the exported report. Review any file or screenshot before attaching it to an issue; the OS version and status information in even the minimal export are still information about your device.

Do not upload complete Application Support or Logs directories, original pending recovery records, credentials, device identifiers, SSIDs, or screenshots containing unrelated personal information. A public GitHub issue is visible to everyone.

## 中文说明

SleepSeal 在本地运行，没有账户、统计 SDK、遥测接口、云同步或远程面板。安装不会上传诊断。打开 GitHub 或 Apple 帮助链接时使用正常浏览器。

应用会读取无线开关、电源设置、锁屏状态、盖子状态、触发角配置、近期进入角落的事件、输入闲置时间和睡眠通知。角落关联只保留近期判断所需信息，不保存鼠标轨迹。诊断会读取阻止睡眠的应用及其电源断言原因；保护功能不需要收集网页内容、Wi-Fi 密码、网络名称或蓝牙设备地址。

上表列出本地文件。用户设置与恢复记录采用私有权限；恢复未完成时不要删除 `pending.json`。持久电源原值与临时睡眠快照分别保存。日志每份最多 1 MiB，保留三份，不会自动上传。卸载在安全恢复后移除启动及安装组件，保留用户诊断／设置文件；持久系统电源值由单独的恢复选项处理。

诊断仅在你主动操作时导出到本地，内容仅包含 SleepSeal／系统版本、保护及待恢复状态、Wi-Fi／蓝牙／低电量开关和权限是否就绪；不包含原始日志、接口名称、阻止睡眠的应用名称或断言描述、用户路径、网络标识、账户信息或待恢复快照。

面板中的睡眠阻止列表与导出分开，可能显示进程名称及应用提供的描述。面板截图或手动复制的日志可能比导出报告透露更多信息。分享任何文件或截图前请检查内容；即使最小导出也包含设备的系统版本和状态。不要公开上传完整用户数据目录、原始待恢复记录、凭据、设备标识、网络名称或含无关私人内容的截图。
