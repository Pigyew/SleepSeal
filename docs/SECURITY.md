# Security / 安全

SleepSeal 0.2.0 is an ad-hoc-signed, unnotarized Beta. It has not received an independent security audit. Developer ID signing, notarization and wider OS validation remain release improvements.

## Boundaries

- The UI, event listeners, recovery store and LaunchAgent run as the current ordinary user. No root daemon is installed.
- The graphical `.pkg` Installer installs the root-owned power tool at `/Library/PrivilegedHelperTools/local.sleepseal.PowerControl` and a per-user sudo rule. The helper and its ancestors must not be symlinks or writable by ordinary users.
- The helper accepts only `set|restore b|c key integer` or the fixed `check`/`claim`/`release`/`finalize-migration`/`uninstall` operations. `check` verifies authorization without changing settings. Allowed keys are `displaysleep`, `sleep`, `powermode`, `lowpowermode`, `powernap`, `tcpkeepalive`, `womp`, and `proximitywake`. New timers are 0–1440; restoring a saved timer accepts a nonnegative Int32. Energy/network values have their own small allowlists. No paths, arbitrary executables, shell strings, or hibernation parameters are accepted.
- The helper verifies root execution, `SUDO_UID`/`SUDO_USER` account consistency, the protected installation and a root-owned per-user authorization record. `pmset` is invoked with a fixed path and argument array. Parsing and all rejected-argument tests run without root or device changes.
- The sudo rule authorizes the parser binary rather than unrestricted `pmset`. Any process already running as that authorized local user can request the same limited operations; this is not a sandbox between that user's applications.
- XPC endpoints check both the user's identity and the current build's designated code requirement. A matching bundle ID or process ID alone is not authorization. An ad-hoc signature identifies a build, not a verified developer identity.
- Root uninstall only handles fixed installation paths and the requesting account's rule/record. It does not delete user files and retains shared components if another SleepSeal rule/record exists. The user process must restore pending transient settings before invoking it.
- The new `sleepseal_v2_<uid>` authorization does not overwrite the prototype's rule during package installation. Only the fixed finalization operation removes that account's legacy rule after the new app confirms readiness and recovery. A failed migration retains the old permission path.
- A fixed root-owned protection-owner file, serialized by a separate root-owned `flock` file, prevents two accounts from starting independent snapshots of the same global hardware state. Claiming is idempotent for the owning UID and rejected for another UID. Release removes only the requester's ownership; another account's release is a no-op. Ownership survives process restart and reboot until the owning account safely finishes recovery. A foreign pending owner also blocks energy/network writes through the helper. Persistent timers remain independent. Own pending ownership prevents uninstall; foreign ownership preserves shared components.

System power writes use a journal before mutation, edited-field conflict checks, readback verification and best-effort rollback. A macOS setting API does not provide an atomic multi-field transaction; an external change can still race with a write. Recovery preserves the original snapshot until restoration is confirmed.

Bluetooth power control, screen-lock verification and unlock notifications partly rely on private interfaces. They may change with macOS releases. Process-level protection cannot guarantee that firmware or a system service never briefly re-enables a radio.

## Reporting

Use GitHub's **Report a vulnerability** private flow when available on this repository. Otherwise, open a minimal issue asking the maintainer for a private contact route; omit exploit steps and sensitive diagnostics until a private route is agreed. Ordinary bugs can use public Issues after reviewing exported diagnostics. Never include credentials, full user state directories, Wi-Fi names or device addresses.

Only 0.2 Beta development receives fixes at present. Old 0.1 source snapshots are retained as provenance, not supported downloads.

## 中文说明

此版本使用临时签名，尚未公证，也未完成独立安全审核。图形安装器仅安装 root 拥有的白名单电源工具和当前用户的授权规则；普通面板、监听器、恢复文件和启动项均由普通用户管理，没有 root 常驻进程。

辅助工具只接受固定操作、电池／接电来源、上述白名单键和严格整数；不接受任意路径、程序、shell 字符串或休眠参数。新时间值限制为 0–1440，恢复旧值可保留非负 Int32 特殊值。执行前验证安装路径、调用用户和 root 授权记录。此规则限制 root 能力，不隔离同一账户中的其他程序。

XPC 同时验证用户及当前构建的代码签名条件；临时签名无法证明开发者身份。固定的 root 周期归属文件通过另一份 root 文件锁串行访问，避免不同账户同时捕获全局硬件状态；另一账户不能抢占或释放已有归属。归属跨进程重启与系统重启保留，必须先回到原账户完成恢复。存在其他账户的待恢复周期时，电源／网络模式写入也会被拒绝；独立的持久时间设置不受影响。此机制经过模拟策略检查，不代表完成多人切换实机测试。

系统电源写入通过保存原值、冲突检查、读回和尽力回滚提高可靠性，但不具有系统级多字段原子事务。私有接口及系统重新启用硬件的行为仍是兼容性边界。

发现安全问题时优先使用仓库可用的私密漏洞报告入口；没有该入口时，可先发布不含技术细节的 Issue，请维护者提供私密联系渠道。不要公开漏洞利用细节、凭据或完整诊断目录。0.1 原型历史仅作来源留存，不作为继续维护的下载版本。
