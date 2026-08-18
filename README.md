<p align="center">
  <img src="OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="96" alt="OpenYoink 图标">
</p>

<h1 align="center">OpenYoink</h1>

<p align="center">
  macOS 拖拽暂存架：把文件、文本、图片、链接先放进屏幕边缘，再拖到目标位置。<br>
  <a href="README.en.md">English</a> · <a href="#安装">安装</a> · <a href="#使用">使用</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-blue" alt="platform">
  <img src="https://img.shields.io/badge/swift-6-orange" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/tests-328%20passing-brightgreen" alt="tests">
</p>

<p align="center">
  <img src="docs/images/banner.jpg" width="720" alt="OpenYoink — 随手一拖，先放一下">
</p>

开始拖拽时暂存架会从屏幕边缘滑出，东西丢上去，腾出手切换窗口，再拖出去。常驻菜单栏，无 Dock 图标。

## 功能

- 拖入：文件/文件夹、文本、富文本、图片、链接，以及邮件、日历事件、联系人等（自动物化为文件）
- 拖出：`fileURL` + file promise 双表示，浏览器上传区也能用；拖到 Finder 一律复制，不动原文件
- 按住 ⌘ 拖入 = 移动进暂存架（原文件进废纸篓，可恢复）
- 出现方式：拖拽自动出现 / 边缘拉环 / ⌘⇧Space（双击存剪贴板）/ 摇动，可按应用忽略
- Quick Look、多选、Stack、框选、手动排序、最近项目
- 多屏、多 Space、全屏应用适配；中英文界面
- 隐私：App Sandbox、无统计上报；仅更新检查联网（可在设置关闭）

## 安装

```bash
brew install --cask muqy1818/tap/openyoink
```

brew 安装不触发 Gatekeeper 弹窗。或从 [Releases](https://github.com/MuQY1818/OpenYoink/releases) 下载 DMG 拖进 Applications——当前为 ad-hoc 签名，首次打开在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/OpenYoink.app
```

（也可以在 系统设置 → 隐私与安全性 点「仍要打开」。）之后的新版本由 Sparkle 自动更新送达。

## 使用

<p align="center">
  <img src="docs/images/usage-demo.gif" width="640" alt="拖入暂存架演示">
</p>

| 操作 | 方式 |
|---|---|
| 显示 / 隐藏 | ⌘⇧Space、菜单栏菜单、单击边缘拉环（同位置再点收起） |
| 添加 | 把任意内容拖到暂存架或拉环上 |
| 移动而非引用 | 按住 ⌘ 拖入 |
| Quick Look | 空格或双击卡片 |
| 移除 | 悬停 ✕、Delete 键或右键菜单 |
| 调位置 | 沿屏幕边缘拖动拉环，或设置中选择 |

设置（菜单栏 → 设置…）：位置与宽度、自动隐藏、拖出后策略、触发方式与灵敏度、忽略的应用、语言。

## 从源码构建

需要 macOS 26+ 与 Xcode 26+。

```bash
git clone https://github.com/MuQY1818/OpenYoink.git
cd Open-Yoink
xcodebuild -project Open-Yoink.xcodeproj -scheme OpenYoink -destination 'platform=macOS' build
xcodebuild -project Open-Yoink.xcodeproj -scheme OpenYoink -destination 'platform=macOS' test
```

SwiftUI 渲染，AppKit 管窗口与拖放；引用式存储 + security-scoped bookmark，JSON 原子写持久化。`DEVELOPMENT_TEAM` 留空供源码本地构建；正式发版脚本要求 Developer ID、Hardened Runtime 和 Apple 公证，不再生成 ad hoc 分发包。

发布前先把公证凭据存入钥匙串，再提供签名身份与 Team ID：

```bash
xcrun notarytool store-credentials openyoink-notary
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (ABCDE12345)'
export DEVELOPMENT_TEAM_ID='ABCDE12345'
export NOTARY_PROFILE='openyoink-notary'
./Scripts/make-release.sh 1.0.2 4
```

脚本在公证和 Gatekeeper 校验通过后才会生成 Sparkle 签名并改写 appcast；上传 GitHub Release、再用脚本输出的 SHA 更新 Homebrew cask，仍需人工确认。

## Roadmap

- v2：剪贴板历史（可选开启，含隐私过滤）
- v3：Handoff、系统扩展

## 致谢与许可

净室实现：研究了多款 MIT 开源 shelf 应用的公开行为，未复制其代码；内置 Sparkle（MIT）用于更新。完整记录见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

[MIT](LICENSE) © 2026 weijue
