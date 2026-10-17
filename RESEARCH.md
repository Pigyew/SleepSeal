# GitHub 检索与技术依据

检索日期：2026-10-17。通过 GitHub 连接器与公开网页检索，并检查项目源码。以下是找到的接近方案，不代表所有项目的穷尽列表。

| 项目 | 睡眠时关闭无线 | 低电量模式 | 休眠相关 | 恢复条件 |
| --- | --- | --- | --- | --- |
| [XSnooze](https://github.com/liuzhcn/xsnooze) | Wi-Fi、蓝牙 | 没有发现实现 | 低电量提醒超时后请求 hibernatemode 25；不能据此证明 M 系列深度休眠 | 系统唤醒 |
| [SleepWatch](https://github.com/metacometdave/SleepWatch) | Wi-Fi、蓝牙 | 没有发现实现 | README 的 deep sleep 描述不等于硬件休眠验证 | 系统唤醒 |
| [Bluesnooze](https://github.com/odlp/bluesnooze) | 蓝牙 | 没有发现实现 | 未实现 | 系统唤醒 |
| [bruvv 的睡眠无线工具](https://github.com/bruvv/macos-wifi-and-bluetooth-off-during-sleep) | Wi-Fi、蓝牙，仅电池条件 | 没有发现实现 | 未实现 | 可选唤醒时恢复 |

没有找到同时满足所有条件的现成项目，尤其是“只能在解锁后恢复”。XSnooze 的 [AppDelegate.swift](https://github.com/liuzhcn/xsnooze/blob/main/Bluesnooze/AppDelegate.swift) 在 `didWakeNotification` 中恢复两种无线。其当前 [v1.7.4 发布页](https://github.com/liuzhcn/xsnooze/releases/tag/v1.7.4) 有 DMG，但功能仍与目标不同。

SleepSeal 根据以下技术资料自行实现，没有复制以上应用源码：

- [Apple：睡眠与唤醒通知](https://developer.apple.com/library/archive/qa/qa1340/_index.html)。使用 IOKit 睡眠前通知并及时确认；额外设置 20 秒确认上限，避免本工具无限阻塞睡眠。
- [Apple pmset 源码](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m)。`powermode` 包括自动、低电量、高性能三态，需要按电源配置保存；源码还说明关闭网络保活对查找等服务的影响。
- [Apple pmset 手册](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.1) 与 [NIST 的 Apple Silicon 讨论](https://github.com/usnistgov/macos_security/issues/338)。传统休眠参数不足以证明 M 系列可以按需进入相同硬件状态，因此保留系统策略。
- [Hammerspoon 的屏幕事件实现](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/caffeinate/libcaffeinate_watcher.m)。区分屏幕解锁、系统唤醒和用户会话切换。
- [CGSession 官方文档](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary())。验证进程所属的图形用户会话；锁屏字典字段本身不是公开稳定接口。
- [blueutil](https://github.com/toy/blueutil)。蓝牙电源控制依赖私有 IOBluetooth 接口，因此需要用户权限和系统版本兼容性验证。
- [Apple Watch 解锁条件](https://support.apple.com/102442)。关闭蓝牙与 Wi-Fi 后，不能依赖 Apple Watch 解锁电脑。

此实现提供尽力控制与状态检查，不能承诺硬件层面永远不会被 macOS 服务重新上电，也不承诺特定节电比例。
