# 0.2.1 Beta verification scope

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
