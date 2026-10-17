# 0.2.1 Beta verification scope

## New app quit-request option — development verification

The new option remains off by default for fresh configurations and configurations migrated without the field. Its UI-only mock driver passed **75 checks**, including default-off state, cancel with no dispatched change, confirmation-only enable, duplicate-confirm prevention, immediate disable and busy-state handling. Native English and Chinese confirmation sheets were presented; a local Return-key event selected Cancel in both languages without changing the preference. Twenty-four simulated screenshots include these confirmation sheets alongside the existing locale/theme and failure cases. No real apps were asked to quit.

The runtime contract limits requests to eligible regular blocking apps of the current console user and selected protection methods, excluding system services. It verifies current process UID, start time, executable and bundle identity before a normal quit; refusal and save dialogs are respected, and there is no force quit or automatic relaunch. SleepSeal's own manual request waits up to 8 seconds and does not proceed while eligible blockers remain unresolved. Idle preparation checks the relevant actual configured timer without promising exact timing. Actual selected sleep preparation has a 2-second best-effort budget. The panel reports requested, exited and remaining counts and cancellation/timeout results.

The complete final app passed the 75 UI checks again with its bundled icon. The full 15-executable simulated suite passed, including 22 app-quit policy scenarios, 39 native-adapter/composition checks and 6 thread-safe cancellation checks. These cover eligibility, identity changes, save prompts/refusal, cancellation, late main-thread work and deadlines; none queried or quit real apps. Source integration was reviewed for selected-method scope and shared sleep deadlines. Simulated checks do not establish real-device app behavior. The transient process identity data is not saved or exported. Full real-app save-dialog/refusal behavior, broader system compatibility and manual VoiceOver traversal remain outside the completed UI verification.

新增退出请求选项对新安装和缺少此字段的旧配置均默认关闭。独立模拟界面通过 **75 项检查**，包含取消无动作、仅确认后启用、重复确认防护、即时关闭及忙碌状态；已实际呈现中英文确认窗口，并用本窗口 Return 键验证默认取消，不修改偏好。24 张模拟截图包含确认窗口，开发验证未请求任何真实应用退出。

运行时约定仅处理已选保护方式和当前前台账户符合条件的普通阻止应用，排除系统服务，正常退出并遵循保存提示／拒绝。手动最多等待 8 秒，未解决则不继续睡眠请求；闲置检查真实相关系统计时，不保证严格倒计时；实际睡眠准备最多 2 秒、尽力而为。进程身份只在本机即时验证，不保存或导出。最终整合应用再次通过 75 项图形检查；15 个测试程序全部通过，其中新增退出策略 22 项、原生适配器及组合模拟 39 项、线程安全取消 6 项。已复核运行时选择范围与共享睡眠准备上限；模拟结果不代表真实应用行为、全部兼容或完整 VoiceOver 已验证。

The release is an early Apple silicon Beta. A minimum deployment target of macOS 13 does not establish runtime compatibility on every supported operating-system version.

Before publication, the project passed its complete `test.sh` suite: the original 63 checks, durable unlock recovery, all 16 trigger combinations, source correlation/configuration, actual core cycle orchestration, persistent settings compare-and-swap and rollback, subprocess deadlines, fixed helper grammar/lease policy, bilingual error presentation, and signed anonymous XPC identity rejection. Hardware mutations are fenced out or mocked in these tests.

The complete app built locally with Swift 6.4 and the macOS 27 SDK in Swift 5 language mode, targeting macOS 13. Its explicit `--ui-self-test` entry passed 60 checks, including a real AppKit control's accessible label, accessibility action dispatch and keyboard focus. Twenty-two owned-window screenshots covered five pages in English/Chinese and light/dark, plus compact conflict and missing-permission states. The screenshots contain simulated data. They were visually reviewed; a complete manual VoiceOver traversal remains outstanding.

The graphical installer was built and expanded without executing its scripts. Verification checked signatures, version, architecture, fixed installation location, payload allowlist, and SHA-256 checksum. Package approval, administrator authorization, production migration and real sleep behavior require user-driven hardware testing. Existing prototype files were preserved during development.

The repository's CI separately checks the macOS 15 SDK with Xcode 16.4 on an ARM64 runner, runs the simulated suite, builds the app/helper and checks a clean installer payload. The workflow result is visible in GitHub Actions; a local build is not a substitute for that result.

No fixed battery-saving percentage, overnight battery-drain improvement, firmware deep-hibernation control, complete hardware matrix, or completed notarization is claimed. The older prototype's manual and lid paths were confirmed on one Apple silicon Mac; expanded Beta behavior still needs broader real-device testing.

## 中文

公开前已通过完整模拟核心测试，以及整合应用中的 60 项图形界面检查；已视检 22 张中英文、浅深色和小窗口截图。辅助工具只测试固定参数及账户归属规则，未在测试中修改真实无线、电源或让电脑睡眠。

安装包已构建、展开并检查文件范围、签名、版本与校验值，未自动执行安装脚本。真实安装、迁移和睡眠测试需要由用户在保存工作后操作。完整人工 VoiceOver 检查、过夜电量对照和全部系统／硬件兼容测试尚未完成。最低 macOS 13 目标不等于这些验证已经完成。

The 0.2.0 graphical installation and user-domain migration were subsequently exercised on one Apple silicon Mac. That found the legacy-path cleanup defect corrected in 0.2.1. This installation observation does not establish real sleep or overnight battery behavior for the new release.

0.2.0 已在一台 Apple 芯片 Mac 完成真实图形安装并接管后台，随后发现并在 0.2.1 修复旧路径清理问题。这不代表新版实际睡眠或过夜耗电已经验证。
