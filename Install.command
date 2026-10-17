#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
task_stage='初始化'
task_temp=''
finish() {
  task_status=$?
  if [[ "$task_status" != 0 ]]; then
    echo "安装未完成，停止在：${task_stage}。请查看上方错误或运行 Check.command。"
  fi
  if [[ -n "$task_temp" ]]; then /bin/rm -rf "$task_temp"; fi
  read -r -p '按回车关闭窗口…' _ || true
}
trap finish EXIT
stage() { task_stage="$1"; printf '\n[%s] %s\n' "$(date '+%F %T')" "$task_stage"; }
if [[ "$(uname -s)" != Darwin ]]; then echo '仅支持 macOS。'; exit 1; fi
if [[ "$EUID" == 0 ]]; then echo '请直接双击安装，不要以 root 运行整个安装程序。'; exit 1; fi
echo 'SleepSeal 0.1.1：睡眠前关闭无线，解锁后恢复。'
echo 'M 系列的深度睡眠由 macOS 管理。关闭无线会影响 Apple Watch 解锁、睡眠联网和查找功能。'
echo '解锁请使用 Mac 内置键盘／触控板／Touch ID 或有线设备。'
task_uid="$(id -u)"
task_user="$(id -un)"
if [[ ! "$task_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
  echo '此账户名需要手工配置权限；安装已停止。'; exit 1
fi
task_app="$HOME/Applications/SleepSeal.app"
task_bin="$task_app/Contents/MacOS/SleepSeal"
task_plist="$HOME/Library/LaunchAgents/local.sleepseal.guard.plist"
task_rule="/private/etc/sudoers.d/sleepseal_${task_uid}"
task_logdir="$HOME/Library/Logs/SleepSeal"
mkdir -p "$task_logdir"
exec > >(/usr/bin/tee -a "$task_logdir/install.log") 2>&1
task_temp="$(mktemp -d)"
app_report() {
  task_mode="$1"
  task_report="$2"
  /bin/rm -f "$task_report"
  /usr/bin/open -W -n "$task_app" --args "$task_mode" "$task_report"
  if [[ ! -f "$task_report" ]]; then
    echo '应用没有返回检查结果。请确认系统已允许打开 SleepSeal。'
    return 1
  fi
  /usr/bin/plutil -extract message raw -o - "$task_report"
  [[ "$(/usr/bin/plutil -extract success raw -o - "$task_report")" == true ]]
}
stage '准备程序文件'
if [[ ! -x build/SleepSeal.app/Contents/MacOS/SleepSeal ]]; then /bin/bash build.sh; fi
if [[ -L "$task_app" || -L "$task_plist" ]]; then echo '目标是符号链接，安装已停止。'; exit 1; fi
# Stop an earlier watcher before replacing the application; keep its recovery record.
if [[ -x "$task_bin" ]]; then
  /bin/launchctl bootout "gui/$task_uid/local.sleepseal.guard" 2>/dev/null || true
fi
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/SleepSeal"
/usr/bin/ditto build/SleepSeal.app "$task_app"
stage '确认应用的蓝牙权限'
echo '此时不会切换无线开关。允许系统授权后，安装会自动继续。'
app_report --permissions "$task_logdir/permission-result.json"
if [[ -f "$HOME/Library/Application Support/SleepSeal/pending.json" ]]; then
  stage '恢复上次保留的设置'
  app_report --recover-report "$task_logdir/recovery-result.json"
fi
stage '安装受限电源权限'
echo '安装限定的电源设置权限，需要一次管理员密码。'
echo '只允许本账户修改列出的电源开关，不授予任意命令权限。'
task_candidate="$task_temp/sleepseal"
for task_scope in -b -c; do
  for task_key in lowpowermode powermode powernap tcpkeepalive womp proximitywake; do
    task_values='0 1'
    if [[ "$task_key" == powermode ]]; then task_values='0 1 2'; fi
    for task_value in $task_values; do
      printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset %s %s %s\n' \
        "$task_user" "$task_scope" "$task_key" "$task_value" >> "$task_candidate"
    done
  done
done
/usr/sbin/visudo -cf "$task_candidate"
/usr/bin/sudo -v
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 /private/etc/sudoers.d
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0440 "$task_candidate" "$task_rule"
stage '在应用内检查无线和电源权限'
if ! app_report --preflight-report "$task_logdir/preflight-result.json"; then
  echo '安装尚未完成，应用和受限电源权限已保留。可修正问题后重试，或运行 Uninstall.command 清理。'
  exit 1
fi
# Construct property values with plutil, so spaces and XML characters in paths are safe.
task_newplist="$task_temp/agent.plist"
/usr/bin/plutil -create xml1 "$task_newplist"
/usr/bin/plutil -insert Label -string local.sleepseal.guard "$task_newplist"
/usr/bin/plutil -insert ProgramArguments -array "$task_newplist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$task_bin" "$task_newplist"
/usr/bin/plutil -insert ProgramArguments.1 -string --watch "$task_newplist"
/usr/bin/plutil -insert RunAtLoad -bool true "$task_newplist"
/usr/bin/plutil -insert KeepAlive -bool true "$task_newplist"
/usr/bin/plutil -insert ThrottleInterval -integer 30 "$task_newplist"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$task_newplist"
/usr/bin/plutil -insert AssociatedBundleIdentifiers -array "$task_newplist"
/usr/bin/plutil -insert AssociatedBundleIdentifiers.0 -string local.sleepseal.guard "$task_newplist"
/usr/bin/plutil -insert StandardOutPath -string "$HOME/Library/Logs/SleepSeal/guard.log" "$task_newplist"
/usr/bin/plutil -insert StandardErrorPath -string "$HOME/Library/Logs/SleepSeal/guard.log" "$task_newplist"
/usr/bin/plutil -lint "$task_newplist"
/bin/cp "$task_newplist" "$task_plist"
/bin/chmod 600 "$task_plist"
stage '启动并验证后台守护'
/bin/rm -f "$task_logdir/runtime-status.json"
/bin/launchctl bootstrap "gui/$task_uid" "$task_plist"
task_ready=false
for task_try in {1..40}; do
  if [[ -f "$task_logdir/runtime-status.json" ]]; then
    task_runtime_ok="$(/usr/bin/plutil -extract success raw -o - "$task_logdir/runtime-status.json" 2>/dev/null || true)"
    task_runtime_pid="$(/usr/bin/plutil -extract pid raw -o - "$task_logdir/runtime-status.json" 2>/dev/null || true)"
    task_service="$(/bin/launchctl print "gui/$task_uid/local.sleepseal.guard" 2>/dev/null || true)"
    task_service_state="$(printf '%s\n' "$task_service" | /usr/bin/awk '$1 == "state" && $2 == "=" && !seen++ {print $3}')"
    task_service_pid="$(printf '%s\n' "$task_service" | /usr/bin/awk '$1 == "pid" && $2 == "=" && !seen++ {print $3}')"
    if [[ "$task_runtime_ok" == true && "$task_service_state" == running && -n "$task_service_pid" && "$task_runtime_pid" == "$task_service_pid" ]]; then task_ready=true; break; fi
    if [[ "$task_runtime_ok" == false ]]; then
      /usr/bin/plutil -extract message raw -o - "$task_logdir/runtime-status.json"
      break
    fi
  fi
  /bin/sleep 0.5
done
if [[ "$task_ready" != true ]]; then
  echo '后台启动验证没有通过，不能确认已生效。请运行 Check.command 查看详情。'
  exit 1
fi
stage '安装完成'
echo '已安装并启用登录自启。它将在下次睡眠时开始工作。'
echo '请先保存工作，再按 README 的步骤验证一次睡眠与解锁。'
echo '暂停并恢复设置：双击 Restore.command；卸载：双击 Uninstall.command。'
