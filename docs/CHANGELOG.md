# Changelog / 更新记录

## 0.2.1 Beta — 2026-10-17

- Fix a real installation migration failure: Foundation standardizes `/private/etc` into `/etc`, which made the helper reject macOS's own alias while checking a correctly installed legacy rule. The verifier now preserves literal paths and still rejects actual symlinks, unsafe ownership and writable directories.
- Add read-only regression checks using real macOS directory/file metadata. Upgrade keeps the user's protection policy and saved state. The 0.2.0 tag remains available as truthful release history; new installs and upgrades should use 0.2.1.

修复实际安装中发现的旧权限清理失败：保留 `/private/etc` 字面路径，继续严格检查 root 所有权、权限与符号链接，并增加真实 macOS 路径的只读回归测试。保留 0.2.0 历史标签，新安装与升级请使用 0.2.1。

## 0.2.0 Beta — 2026-10-17

- Native menu bar and five-page dashboard with English, Simplified Chinese and system-language choice; setup and repair remain available when protection cannot start.
- All-method protection or independent manual/lid/Hot Corner/idle selection, with conservative behavior for unknown sources in Custom mode. The exact manual entry is SleepSeal's own Sleep now action.
- Sleep-cycle-bound unlock candidates with delayed verification retry, durable partial recovery, bounded sleep preparation and rotating logs.
- Separate persistent battery/adapter display and sleep timers and supported energy modes; edited-field conflict checks, readback, first-original backup and partial rollback. Apple silicon deep sleep remains macOS-managed.
- Narrow root-owned helper, graphical `.pkg`, safe current-user migration and restore-before-pause/quit/uninstall behavior. Temporarily signed and unnotarized; not a production security or compatibility certification.
- Expanded simulated policy, recovery, preference and helper checks; bilingual documentation and macOS ARM64 CI. Real-device and overnight behavior still require wider validation.

新增原生菜单栏、五页双语面板、可组合保护方式、延迟解锁验证重试、持久电源设置、受限辅助工具与图形安装／迁移。恢复记录与持久电源备份分开管理，部分失败保留重试。当前为临时签名 Beta，M 系列深度睡眠由系统管理，尚无全面兼容或过夜省电认证。

## Imported prototypes

These are source archive imports with actual import dates, not original historical Git commits. See [provenance and hashes](HISTORY.md).

| Snapshot | Change |
|---|---|
| 0.1.2 | Added actual display-sleep notifications and Hot Corner configuration diagnostics to existing system sleep handling. |
| 0.1.1 | Repaired GUI permission handoff and installation readiness reporting. |
| 0.1.0 | Initial Apple silicon sleep protection, original-state recording and unlock-only recovery prototype. |

原型按真实导入日期保留来源：0.1.0 为初版；0.1.1 修复授权传递和安装状态；0.1.2 加入实际显示器睡眠事件及触发角配置诊断。历史源码不等于继续维护的旧安装包。
