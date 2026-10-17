# Contributing / 贡献指南

Bug reports, documentation fixes and focused pull requests are welcome under the [MIT license](../LICENSE).

1. Search existing issues. Include SleepSeal version, macOS version, Apple chip, selected trigger methods and whether an external display was connected.
2. Describe expected/observed behavior and whether it happened before unlock or after unlock. A radio being on after successful recovery is expected when it was on before sleep.
3. Review a locally exported diagnostic report before sharing it. Never attach full logs/state directories or credentials. Use [private reporting](SECURITY.md) for security vulnerabilities.

Develop on Apple silicon with Xcode or Command Line Tools:

```sh
bash test.sh
bash build.sh
bash package.sh
```

Automated tests must use mocked adapters. They must not mutate real power settings, disable a radio, request real sleep, invoke sudo, or install/uninstall the package. New recovery tests should cover durable state and failure behavior; UI changes should retain both languages, keyboard access, small-window scrolling and native light/dark behavior. Read [the UX contract](UX_CONTRACT.md).

Hardware validation is separate and explicit: save work, use built-in/wired input and record the original settings. A successful simulated test or screenshot is not a hardware, overnight battery, or manual VoiceOver verification. Note exactly which OS/device combinations you checked.

Keep source changes focused. Do not commit `build/`, compiled apps/installers, logs, recovery/configuration files, credentials, chat data, archive metadata or caches. Release assets must be clean rebuilds with checksums. Imported prototype snapshots use actual import dates and documented provenance; never backdate commits to invent history.

## 中文说明

欢迎提交错误报告、文档修正和范围明确的 Pull Request。报告时请注明应用／macOS 版本、Apple 芯片、所选触发方式及外接显示器情况，并区分解锁前和解锁后的状态。分享诊断前检查私人内容；安全问题请使用[私密报告流程](SECURITY.md)。

自动测试必须使用模拟适配器，不可更改真实电源、断网、睡眠、运行 sudo 或安装／卸载。界面修改需要保留中英文、键盘操作、小窗口滚动及系统浅深色支持。硬件测试需要另行明确执行，并记录实际验证的设备和系统；模拟测试和截图不能冒充过夜耗电或 VoiceOver 实测。

请勿提交构建缓存、应用／安装包、日志、恢复记录、凭据、聊天数据或归档元数据。发布安装包需要干净构建与校验值；原型历史应保留真实导入日期，不伪造时间。
