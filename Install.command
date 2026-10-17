#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
finish() { read -r -p '按回车关闭窗口…' _ || true; }
trap finish EXIT
if [[ "$(uname -s)" != Darwin ]]; then echo '仅支持 macOS。'; exit 1; fi
if [[ "$EUID" == 0 ]]; then echo '请直接双击安装，不要以 root 运行整个安装程序。'; exit 1; fi
echo 'SleepSeal 0.1：睡眠前关闭无线，解锁后恢复。'
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
if [[ ! -x build/SleepSeal.app/Contents/MacOS/SleepSeal ]]; then /bin/bash build.sh; fi
if [[ -L "$task_app" || -L "$task_plist" ]]; then echo '目标是符号链接，安装已停止。'; exit 1; fi
# Upgrade only after safely recovering an earlier installation.
if [[ -x "$task_bin" ]]; then
  /bin/launchctl bootout "gui/$task_uid/local.sleepseal.guard" 2>/dev/null || true
  "$task_bin" --recover
fi
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/SleepSeal"
/usr/bin/ditto build/SleepSeal.app "$task_app"
echo '接下来申请蓝牙权限；此时不会切换无线开关。'
/usr/bin/open -W "$task_app" --args --permissions
"$task_bin" --check-permission
"$task_bin" --doctor
echo '安装限定的电源设置权限，需要一次管理员密码。'
echo '只允许本账户修改列出的电源开关，不授予任意命令权限。'
task_temp="$(mktemp -d)"
cleanup() { /bin/rm -rf "$task_temp"; finish; }
trap cleanup EXIT
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
if ! "$task_bin" --preflight; then
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
/usr/bin/plutil -insert StandardOutPath -string "$HOME/Library/Logs/SleepSeal/guard.log" "$task_newplist"
/usr/bin/plutil -insert StandardErrorPath -string "$HOME/Library/Logs/SleepSeal/guard.log" "$task_newplist"
/usr/bin/plutil -lint "$task_newplist"
/bin/cp "$task_newplist" "$task_plist"
/bin/chmod 600 "$task_plist"
/bin/launchctl bootstrap "gui/$task_uid" "$task_plist"
echo '已安装并启用登录自启。它将在下次睡眠时开始工作。'
echo '请先保存工作，再按 README 的步骤验证一次睡眠与解锁。'
echo '暂停并恢复设置：双击 Restore.command；卸载：双击 Uninstall.command。'
