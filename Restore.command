#!/bin/bash
set -euo pipefail
trap 'read -r -p "按回车关闭窗口…" _ || true' EXIT
if [[ "$EUID" == 0 ]]; then echo '请用普通用户运行。'; exit 1; fi
task_bin="$HOME/Applications/SleepSeal.app/Contents/MacOS/SleepSeal"
if [[ ! -x "$task_bin" ]]; then echo '找不到已安装的 SleepSeal。'; exit 1; fi
/bin/launchctl bootout "gui/$(id -u)/local.sleepseal.guard" 2>/dev/null || true
"$task_bin" --recover
echo '已暂停守护并恢复保存的设置。下次登录会重新启动；彻底移除请运行 Uninstall.command。'
