#!/bin/bash
set -euo pipefail
trap 'read -r -p "按回车关闭窗口…" _ || true' EXIT
cd "$(dirname "$0")"
task_bin="$HOME/Applications/SleepSeal.app/Contents/MacOS/SleepSeal"
if [[ ! -x "$task_bin" ]]; then task_bin="$PWD/build/SleepSeal.app/Contents/MacOS/SleepSeal"; fi
"$task_bin" --doctor
task_log="$HOME/Library/Logs/SleepSeal/guard.log"
if [[ -f "$task_log" ]]; then
  echo '最近的守护日志：'
  /usr/bin/tail -n 25 "$task_log"
fi
