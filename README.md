# Open-Yoink

一个**开源、原生、简洁**的 macOS 拖拽暂存工具：把文件、文本、图片、链接先放进屏幕边缘的「暂存架（shelf）」，切换到目标窗口后再一次性拖出去。

> 灵感来自 Yoink（Eternal Storms Software 的商业产品）。Open-Yoink 是独立的清洁实现，与其无任何隶属关系。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 功能

- 📥 **拖入暂存**：从 Finder、浏览器、邮件等任意支持拖放的应用，把文件/文件夹/文本/图片/URL 拖进 shelf，只保存引用、不复制原文件。
- 📤 **拖出到任意目标**：再拖到 Finder、浏览器上传区、聊天、邮件附件等位置；文件同时提供 `fileURL` 与 file promise 双表示，兼容网页上传。
- 👀 **Quick Look 预览**：空格或双击预览图片、PDF、文本等。
- 🗂 **多选与 Stack**：多选批量拖出，可将多个项目合并为一个 Stack。
- ⚡️ **多种触发方式**：全局快捷键（默认 ⌘⇧Space）、可选鼠标摇动、可选屏幕边缘触发。
- 🖥 **多屏 / 多 Space / 全屏**：shelf 可跟随鼠标所在屏幕，跨 Space 与全屏应用保持可用。
- 🎛 **可定制**：位置、宽度、自动隐藏、拖出后策略、忽略应用列表、快捷键自定义。
- 🌐 **中英文界面**，跟随系统语言。
- 🔒 **隐私优先**：本地存储、App Sandbox、不请求辅助功能权限、不联网。

## 系统要求

- macOS 26 (Tahoe) 或更高版本
- 构建需 Xcode 26+ / Swift 6.3+

## 构建

```bash
git clone https://github.com/<you>/Open-Yoink.git
cd Open-Yoink
open Open-Yoink.xcodeproj
```

在 Xcode 中 `Cmd+R` 运行。应用以菜单栏 agent 运行（无 Dock 图标）。

## 使用

1. 点击菜单栏图标或按 **⌘⇧Space** 唤出 shelf。
2. 把文件拖进 shelf，松开鼠标后切换到目标应用。
3. 从 shelf 把项目拖到目标位置。

## 首次运行提示

如果下载的是未公证版本，macOS 可能提示「无法打开」。请在「应用程序」中**右键点击 → 打开**，或在「系统设置 → 隐私与安全性」中允许运行。

## 许可证

[MIT](LICENSE) © weijue

---

## English

An open-source, native, minimal drag-and-drop shelf for macOS. Stage files, text, images and links on a shelf at the screen edge, then drag them out to any destination. See the Chinese section above for full documentation.
