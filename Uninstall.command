#!/bin/bash
set -euo pipefail
trap 'read -r -p "按回车关闭窗口…" _ || true' EXIT
if [[ "$EUID" == 0 ]]; then echo '请用普通用户运行。'; exit 1; fi
task_uid="$(id -u)"
task_app="$HOME/Applications/SleepSeal.app"
task_bin="$task_app/Contents/MacOS/SleepSeal"
task_plist="$HOME/Library/LaunchAgents/local.sleepseal.guard.plist"
task_state="$HOME/Library/Application Support/SleepSeal/pending.json"
/bin/launchctl bootout "gui/$task_uid/local.sleepseal.guard" 2>/dev/null || true
if [[ -x "$task_bin" ]]; then
  # Never remove the recovery record or privileges before restoration succeeds.
  if [[ -f "$task_state" ]]; then
    task_report="$(mktemp -t sleepseal-recovery)"
    /bin/rm -f "$task_report"
    /usr/bin/open -W -n "$task_app" --args --recover-report "$task_report"
    if [[ ! -f "$task_report" ]]; then echo '应用未返回恢复结果，原设置记录已保留。'; exit 1; fi
    /usr/bin/plutil -extract message raw -o - "$task_report"
    task_ok="$(/usr/bin/plutil -extract success raw -o - "$task_report")"
    /bin/rm -f "$task_report"
    [[ "$task_ok" == true ]]
  fi
elif [[ -e "$task_state" ]]; then
  echo '仍有待恢复的设置，但应用已丢失。请先重新安装，再卸载。'; exit 1
fi
/usr/bin/sudo /bin/rm -f "/private/etc/sudoers.d/sleepseal_${task_uid}"
/bin/rm -f "$task_plist"
/bin/rm -rf "$task_app"
echo '已恢复设置并移除应用、自启和电源权限。诊断日志保留在 ~/Library/Logs/SleepSeal。'
