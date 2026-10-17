# Changelog / 更新记录

## 0.2.2 Beta — unreleased / 尚未发布

- Journal pending persistent writes separately from the last confirmed value, including rollback. Old backup arrays remain readable; interrupted repeated edits and restoration remain recoverable without overwriting external changes.
- Keep a valid transient recovery engine available when app settings or the separate persistent-power backup are damaged or use a future schema. Preserve those files, pause new protection/edits, and permit verified recovery. Service repair startup also tolerates damaged app settings.
- Separate current diagnostic failures from unresolved operation/startup failures. Defer setup for the current process without re-opening it on every refresh.
- Stage user startup files before privileged uninstall; roll back before commit and retry cleanup alone after commit. Freeze configuration and protection for the whole uninstall/quit lifecycle.
- Process manual quit preparation in batches under one 8-second deadline, with a final complete inventory before sleep. Keep actual-sleep preparation at its existing 2-second best-effort limit.
- Refresh stable hidden diagnostics every 60 seconds, retain 10-second pending/visible checks, cache capability/authorization display reads, and submit pointer work only on corner occupancy changes. Re-read corner configuration at those transitions and at actual sleep; fence delayed unlock callbacks at notification receipt.
- Add headless dashboard, startup/recovery, queued-event and uninstall integration tests; sandbox installer failures; validate bilingual format arguments. Centralize VERSION, check clean build/package provenance, and publish only the package from the successful tag workflow. GUI checks have an explicit logged-in-runner workflow.

修复恢复日志中断窗口、损坏配置阻断连接恢复、旧错误残留及向导反复出现；卸载改为可回滚暂存和提交后独立清理。手动退出准备完整检查所有批次，后台减少重复命令和指针任务。补充组合回归、安装故障测试、双语格式检查及构建来源验证。仍为未公证 Beta，未声称新增实机兼容或过夜省电验证。

## 0.2.1 Beta — 2026-10-17

- Add an optional, default-off request to normally quit eligible sleep-blocking apps belonging to the current console user. Enabling requires a bilingual confirmation; system services are excluded, save prompts and refusals are respected, and exited apps are not automatically relaunched. No force-quit operation is offered.
- Scope quit requests to selected sleep methods. SleepSeal's own sleep action waits up to 8 seconds and stops if blockers remain unresolved; automatic idle preparation checks the relevant configured system timer, and actual-sleep preparation is limited to 2 seconds of best effort. The panel shows requested/exited/remaining counts and cancellation or timeout status.
- Verify process UID, start time, executable and bundle information locally before requests without saving or exporting that transient identity data. Add simulated policy/process checks and opt-in UI checks; no real apps are asked to quit in development tests.

新增默认关闭的“睡眠前请求退出阻止睡眠的应用”。启用前需确认风险，仅处理当前前台账户符合条件的普通应用，排除系统服务，遵循保存提示和拒绝，不强制退出、不自动重启应用。请求遵循已选保护方式；SleepSeal 手动睡眠最多等待 8 秒，未解决则停止本次请求；闲置准备检查相关系统计时，实际睡眠准备最多 2 秒、尽力而为。面板显示请求／退出／仍运行数量和取消／超时状态。身份信息仅供本机即时验证，不保存或导出；开发验证使用模拟应用。

- Add the teal moon-and-shield application icon to Finder, Spotlight, the dashboard and setup, with a standard macOS `.icns` resource.

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
