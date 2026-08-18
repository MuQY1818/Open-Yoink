<p align="center">
  <a href="https://muqy1818.github.io/OpenYoink/">
    <img src="OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="104" alt="OpenYoink 图标">
  </a>
</p>

<h1 align="center">OpenYoink</h1>

<p align="center"><strong>随手一拖，先放一下。</strong></p>

<p align="center">
  原生 macOS 拖拽暂存架：把文件、文本、图片和链接暂存在屏幕边缘，<br>
  切换到目标位置后再拖出去。
</p>

<p align="center">
  <a href="https://github.com/MuQY1818/OpenYoink/releases/latest"><img src="https://img.shields.io/github/v/release/MuQY1818/OpenYoink?display_name=tag&sort=semver&style=flat-square" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 15+"><img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/MuQY1818/OpenYoink?style=flat-square" alt="MIT 许可证"></a>
</p>

<p align="center">
  <a href="https://github.com/MuQY1818/OpenYoink/releases/latest">下载</a> ·
  <a href="#安装">安装</a> ·
  <a href="https://muqy1818.github.io/OpenYoink/">官网</a> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/MuQY1818/OpenYoink/releases/latest">
    <img src="docs/images/banner.jpg" width="760" alt="OpenYoink — 随手一拖，先放一下">
  </a>
</p>

## 它解决什么问题

在 Finder、浏览器、邮件或其他应用之间搬东西时，目标窗口往往不在眼前。OpenYoink 提供一个临时落脚点，让一次跨窗口拖拽变成三个简单动作：

| 1. 拖入 | 2. 切换 | 3. 拖出 |
|:---:|:---:|:---:|
| 开始拖拽，暂存架自动从屏幕边缘出现 | 自由切换窗口、Space 或全屏应用 | 把内容从暂存架拖到最终位置 |

<p align="center">
  <img src="docs/images/usage-demo.gif" width="720" alt="将文件拖入 OpenYoink 暂存架的演示">
</p>

OpenYoink 常驻菜单栏，不显示 Dock 图标；需要时出现，用完后收起。

## 核心亮点

- **接住常用内容**：文件、文件夹、纯文本、富文本、图片、链接，以及邮件、日历事件、联系人等内容。
- **多种唤出方式**：开始拖拽时自动出现，也可以使用边缘拉环、全局快捷键或鼠标摇动手势。
- **整理而不打断**：支持 Quick Look、多选、框选、Stack、手动排序和最近项目。
- **适应复杂桌面**：支持多显示器、多 Space 和全屏应用，还可以按应用关闭自动唤出。
- **可预期的文件语义**：默认引用原文件；拖到 Finder 时只请求复制。按住 ⌘ 拖入会启用托管移动流程，详见[文件安全与生命周期](#文件安全与生命周期)。
- **原生且克制**：SwiftUI + AppKit，支持中英文界面、登录时启动和 Sparkle 自动更新。

## 安装

**系统要求：macOS 15 Sequoia 或更高版本。** Release 构建同时面向 Apple Silicon 与 Intel Mac。

### Homebrew（推荐）

```bash
brew install --cask muqy1818/tap/openyoink
```

Homebrew cask 下载对应版本的 GitHub Release DMG，并在安装后移除这一应用的隔离属性，因此通常不会出现 Gatekeeper 拦截。这个步骤不会改变安装包的签名，也不等同于 Apple 公证。安装后，OpenYoink 可以通过 Sparkle 检查后续更新。

### 手动安装

1. 从 [GitHub Releases](https://github.com/MuQY1818/OpenYoink/releases/latest) 下载最新 DMG。
2. 打开 DMG，将 OpenYoink 拖入 `Applications`。
3. 首次启动若被 macOS 拦截，在 Finder 中右键 OpenYoink 并选择“打开”，或前往“系统设置 → 隐私与安全性”允许打开。

> [!NOTE]
> GitHub Releases 中的免费社区构建使用 ad-hoc 签名，但没有经过 Apple 公证，因此首次手动安装可能触发系统提示。Sparkle EdDSA 签名保护的是安装后的更新包完整性，不能替代首次下载校验或 Apple 公证。

<details>
<summary>仍然无法打开？</summary>

仅在确认应用来自上面的 OpenYoink 官方 Release 地址后使用。可以先运行 `shasum -a 256 OpenYoink-VERSION.dmg`（把 `VERSION` 换成实际版本号），并与同版本 [Homebrew cask](https://github.com/MuQY1818/homebrew-tap/blob/main/Casks/openyoink.rb) 中的 `sha256` 比对。下面的命令会明确绕过这一个应用的 Gatekeeper 隔离检查：

```bash
xattr -dr com.apple.quarantine /Applications/OpenYoink.app
```

</details>

## 快速上手

| 操作 | 方式 |
|---|---|
| 显示 / 隐藏暂存架 | `⌘⇧Space`、菜单栏菜单，或单击屏幕边缘的拉环 |
| 添加内容 | 把内容拖到暂存架或边缘拉环上 |
| 移动而非引用 | 按住 `⌘` 拖入文件或文件夹 |
| 暂存当前剪贴板内容 | 连按两次 `⌘⇧Space` |
| Quick Look | 选中卡片后按 `Space`，或双击卡片 |
| 多选 | 按住 `⌘` 点选，或在空白处拖动框选 |
| 移除 | 悬停后点 `×`、按 `Delete`，或使用右键菜单 |
| 调整位置 | 沿屏幕边缘拖动拉环，或在设置中选择位置 |

菜单栏中的“设置…”还可以调整暂存架宽度、自动隐藏、拖出后处理策略、触发灵敏度、忽略的应用、登录时启动、存储管理和界面语言。普通项目拖出后的默认策略是保留在暂存架，可改为移除或每次询问。

## 支持的内容

| 内容 | OpenYoink 的处理方式 |
|---|---|
| 文件与文件夹 | 默认保留对原位置的 sandbox bookmark，不复制一份到暂存架 |
| 纯文本与链接 | 直接记录在暂存架数据中 |
| 图片、HTML 与 RTF | 在应用沙箱的托管目录中物化为文件 |
| 联系人、日历事件与邮件 | 当来源应用提供可读数据时，物化为 `.vcf`、`.ics` 与 `.eml` 文件 |

拖出文件时，OpenYoink 同时提供文件 URL 与 file promise，以兼容 Finder 和常见浏览器上传区域；最终是否接受仍由目标应用或网站决定。

## 文件安全与生命周期

- **普通文件与文件夹拖入**只保存对原位置的引用。移除卡片或选择“拖出后移除”不会删除原文件；如果原文件被移动、删除或所在磁盘离线，卡片会显示为不可用，直到 bookmark 能再次解析。
- **按住 ⌘ 拖入文件或文件夹**时，OpenYoink 会先把内容复制到应用沙箱的托管目录并确认副本存在，再把原文件移入废纸篓。任一步失败都会保留原文件并回退为普通引用。原文件仅在废纸篓尚未清空时可恢复。
- **托管移动项目拖出成功**后，目标位置收到文件，暂存架卡片和托管副本随即删除；该行为不受普通项目的“拖出后处理”设置影响。取消或交付失败时，项目与托管副本会保留以便重试。
- **文本与链接**随卡片保存在暂存架数据中，移除卡片时一并移除。图片、富文本、邮件等物化文件在卡片被手动移除或按策略移除后会失去引用，并在下次启动的安全清理中删除；也可以在“设置 → 存储”中立即查看和清理。

## 隐私与设计

- 启用 App Sandbox；暂存架数据和物化文件保存在沙箱内的 `Application Support/OpenYoink`，可从“设置 → 存储”打开数据目录或清理未使用文件。
- 不需要账号，也不包含分析统计或遥测上报。正常使用不要求辅助功能或输入监控权限；文件访问范围来自用户主动拖入的内容。
- 当前版本的自动更新检查默认开启，可在设置中关闭。自动或手动检查更新都会访问 GitHub Pages / Releases；当前版本没有其他后台联网功能。
- 当前版本只有在用户执行“连按两次快捷键暂存剪贴板”时，才会读取当前剪贴板内容。
- 持久化采用 security-scoped bookmarks 与原子 JSON 写入，以减少不必要的原文件复制和部分写入造成的快照损坏风险。

## 从源码构建

开发环境需要 macOS 15+ 与 Xcode 26+。

```bash
git clone https://github.com/MuQY1818/OpenYoink.git
cd OpenYoink

xcodebuild \
  -project Open-Yoink.xcodeproj \
  -scheme OpenYoink \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project Open-Yoink.xcodeproj \
  -scheme OpenYoink \
  -destination 'platform=macOS' \
  test
```

本地构建无需设置 `DEVELOPMENT_TEAM`。项目使用 SwiftUI 渲染界面，以 AppKit 管理窗口、拖放和全局事件；测试覆盖持久化、拖入拖出、快捷键、触发器和布局等核心行为。

维护者可通过 [`Scripts/make-release.sh`](Scripts/make-release.sh) 生成 Developer ID + 公证的正式构建，或显式使用 `--adhoc` 生成免费社区构建。脚本不会在签名失败时静默降级发布模式。

## 参与项目

欢迎提交 [Issue](https://github.com/MuQY1818/OpenYoink/issues) 和 Pull Request。

- Bug 报告请附上 macOS 版本、OpenYoink 版本、复现步骤和预期行为。
- 较大的功能改动建议先开 Issue 讨论，避免双方在目标上产生偏差。
- 提交代码前请运行完整测试，并保持改动聚焦、说明清楚。

## Roadmap

- [ ] 可选的剪贴板历史与隐私过滤
- [ ] Handoff 与更深的系统集成

Roadmap 表示探索方向，不承诺具体版本或时间；优先级会根据稳定性和用户反馈调整。

## 致谢与许可

OpenYoink 是独立的开源实现，与商业应用 Yoink 及其开发者没有隶属、授权或背书关系。自动更新由 [Sparkle](https://sparkle-project.org/) 提供。

第三方组件与许可证见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。项目基于 [MIT License](LICENSE) 开源。

© 2026 weijue
