#!/bin/bash
set -euo pipefail
trap 'read -r -p "按回车关闭窗口…" _ || true' EXIT
if [[ "$(uname -s)" != Darwin ]]; then echo '仅支持 macOS。'; exit 1; fi
if [[ "$EUID" == 0 ]]; then echo '请用普通用户运行检查。'; exit 1; fi
task_plist="$HOME/Library/LaunchAgents/local.sleepseal.guard.plist"
task_logdir="$HOME/Library/Logs/SleepSeal"
task_report="$task_logdir/runtime-status.json"
task_pending="$HOME/Library/Application Support/SleepSeal/pending.json"
task_running=false

echo 'SleepSeal — 只读检查（不会切换无线或电源设置）'
if [[ -f "$task_plist" ]]; then
  echo '登录自启文件：存在'
else
  echo '登录自启文件：不存在，安装尚未完成或已被移除'
fi

if task_service="$(/bin/launchctl print "gui/$(id -u)/local.sleepseal.guard" 2>&1)"; then
  task_state="$(printf '%s\n' "$task_service" | /usr/bin/awk '/^[[:space:]]*state = / {print $3; exit}')"
  task_pid="$(printf '%s\n' "$task_service" | /usr/bin/awk '/^[[:space:]]*pid = / {print $3; exit}')"
  if [[ "$task_state" == running && -n "$task_pid" ]]; then
    task_running=true
    echo "后台服务：运行中（进程 ${task_pid}）"
  else
    echo "后台服务：已注册，但当前没有运行（状态：${task_state:-无法读取}）"
  fi
else
  echo '后台服务：未注册／未运行'
fi

if [[ -f "$task_pending" ]]; then
  echo '恢复记录：存在，仍有保存的睡眠前设置；请保留该记录'
else
  echo '恢复记录：当前没有待恢复记录'
fi

if [[ "$task_running" == true ]]; then
  if [[ -f "$task_report" ]]; then
    task_report_pid="$(/usr/bin/plutil -extract pid raw -o - "$task_report" 2>/dev/null || true)"
    if [[ "$task_report_pid" != "$task_pid" ]]; then
      echo '后台诊断来自较早的进程，当前实例尚未返回状态，不能据此确认已就绪。'
    else
      echo '后台进程最近一次诊断（文件内时间表示采集时间；mostRecentFailure 是保留的最近失败）：'
    fi
    if ! /usr/bin/plutil -p "$task_report"; then
      echo '诊断报告无法读取，请查看下方日志。'
    fi
  else
    echo '后台诊断报告：尚未生成；请查看下方日志。'
  fi
else
  echo '安装未完成，或后台服务已停止；本次睡眠策略没有正在运行的守护进程执行。'
  echo '请查看安装日志后重新运行 Install.command，看到安装成功提示后再测试睡眠。'
fi

for task_logname in install.log guard.log; do
  task_log="$task_logdir/$task_logname"
  if [[ -f "$task_log" ]]; then
    echo "最近的 ${task_logname}（末 25 行）："
    /usr/bin/tail -n 25 "$task_log"
  else
    echo "${task_logname}：暂无日志"
  fi
done

if [[ "$task_running" != true ]]; then exit 1; fi
