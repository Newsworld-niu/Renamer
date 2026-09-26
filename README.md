# Renamer

简体中文 | [English](README.en.md)

Renamer 是一个用于 macOS 桌面（Space）的命名工具。它在 Mission Control 的桌面缩略图上显示自定义名称，也可以按名称搜索并切换桌面。当前公开版本为 **0.1.0 预览版**。

## 下载与安装

1. 到 [Releases](https://github.com/Newsworld-niu/Renamer/releases) 下载 `Renamer-v0.1.0-arm64.dmg`。GitHub 自动生成的「Source code」压缩包只有源码，不是应用。
2. 双击打开 DMG，把 `Renamer.app` 拖到「Applications / 应用程序」，推出磁盘映像后从「应用程序」打开 Renamer。
3. 此预览版尚未经过 Apple 公证。如果 macOS 阻止首次打开，先尝试打开一次，再到「系统设置 → 隐私与安全性」点击「仍要打开」。无需关闭系统安全保护。
4. 按应用提示授予「辅助功能」权限，才能在 Mission Control 显示名称和切换桌面。

此安装包适用于 Apple 芯片 Mac。下载者无需安装 Xcode 或运行下面的构建命令。

## 功能

- 为不同屏幕上的普通桌面分别命名，在 Mission Control 中显示名称。
- 通过菜单栏查看、切换和重命名桌面。
- 可选择是否启用桌面搜索；启用后可设置全局搜索快捷键。
- 可调整缩略图名称的颜色、位置和字号；另有独立的当前桌面名称开关。
- 名称与设置保存在本机；可选择开机自动运行。

## 系统要求

Apple 芯片、macOS 14 或更新版本。当前仅在 macOS 26.3 上进行过实际测试。Renamer 使用 macOS 未公开的桌面接口，系统更新后可能需要适配。

## 从源码构建

需要 Xcode Command Line Tools。首次构建时，在项目根目录运行：

```sh
zsh app/setup-signing.sh
zsh app/build.sh
open dist/Renamer.app
```

`setup-signing.sh` 在本机钥匙串创建开发用签名身份，后续构建会复用它。私钥保存在钥匙串中，不属于仓库。构建结果位于 `dist/Renamer.app`；首次使用时，按应用提示在系统设置中授予辅助功能权限。当前签名供本机开发使用，并非 Apple 公证的公开发行版。

## 使用

在主窗口为桌面输入名称。顶部缩略图名称会在 Mission Control 中显示。菜单栏可用于切换桌面、重命名和打开设置。

主窗口中的“启用桌面搜索”控制搜索功能。关闭时，搜索入口和全局快捷键都会停用；重新开启后会恢复之前保存的快捷键。首次安装默认开启，快捷键可在主窗口修改。

名称数据位于 `~/Library/Application Support/Renamer/names.json`，不会自动上传。某些桌面不提供持久 UUID；这类桌面跨系统重启时，只有相邻桌面的身份足以唯一确认时才恢复名称，否则保留原记录，避免误配。

## 反馈问题与参与贡献

遇到问题或有功能建议，欢迎在 [Issues](https://github.com/Newsworld-niu/Renamer/issues) 新建 Issue。报告问题时，请尽量写明 Renamer 与 macOS 版本、Mac 型号、复现步骤，以及预期和实际结果。截图或诊断信息也有帮助；分享日志或 `names.json` 前，请检查其中是否包含你的桌面名称等私人信息。

欢迎通过 [Pull Requests](https://github.com/Newsworld-niu/Renamer/pulls) 改进代码、文档和翻译。较大的改动可以先开 Issue 讨论；提交 PR 时请说明改动原因和验证方式，并尽量让每个 PR 聚焦一件事。
