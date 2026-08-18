<p align="center">
  <img src="OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="96" alt="OpenYoink 图标">
</p>

<h1 align="center">OpenYoink</h1>

<p align="center">
  一个开源、原生的 macOS 拖拽暂存架：把文件、文本、图片、链接先放进屏幕边缘，再从容地拖到目标位置。<br>
  <a href="README.md">English</a> · <a href="#功能">功能</a> · <a href="#安装">安装</a> · <a href="#使用">使用</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-blue" alt="platform">
  <img src="https://img.shields.io/badge/swift-6-orange" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/tests-328%20passing-brightgreen" alt="tests">
</p>

<p align="center">
  <img src="docs/screenshots/shelf-with-items.png" width="360" alt="暂存架界面">
</p>

OpenYoink 常驻菜单栏（无 Dock 图标）。开始拖拽时，紧凑的暂存架会从屏幕边缘滑出——把东西丢上去，解放鼠标去切换窗口，再拖出来放到目标位置。本项目是独立净室实现（见 <a href="THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>）。

## 功能

**几乎什么都能拖入**
- Finder 文件/文件夹；浏览器与其他应用的图片、文本、富文本（HTML/RTF）、链接；file promise（如照片 app）
- 万能兜底：邮件（.eml）、日历事件（.ics）、联系人（.vcf）及其他数据内容自动物化为正规文件
- 按住 **⌘** 拖入 = 把原文件**移动**进暂存架保管（原文件进废纸篓，可恢复）

**拖到任何地方**
- 文件双表示（`fileURL` + file promise），兼容浏览器上传区（最佳努力）
- 拖到 Finder 一律是复制——除非你用了 ⌘ 剪切模式，否则绝不动原文件
- 多选与 Stack 可整批拖出

**需要时它就在**
- 开始拖拽自动出现（可配置：立即 / 贴近屏幕边缘才出现 / 关闭）
- 隐藏时屏幕边缘常驻小拉环——单击展开、可拖文件上去、沿边拖动换位、推向对侧换边
- 全局快捷键 ⌘⇧Space（可自定义）；双击快捷键把剪贴板存进暂存架
- 可选鼠标摇动触发；可按应用忽略

**不添乱的暂存架**
- 高度贴合内容；空了自动收起
- 可贴左/右缘或自由摆放；内缘箭头一键收起；卡片悬停 ✕ 移除
- Quick Look（空格或双击，支持多选翻页）、打开 / 在 Finder 显示 / 右键菜单
- Stack、框选、手动排序、最近项目菜单
- 多屏 / 多 Space / 全屏应用适配；中英文界面
- 基于 Sparkle 2 的自动更新——EdDSA 签名，从 GitHub Releases 分发

**隐私优先**
- App Sandbox、不申请辅助功能权限、无统计上报——一切只存在你的 Mac 上
- 唯一的联网行为是更新检查（Sparkle → GitHub Pages feed 与 Releases 下载），可在「设置 → 通用」关闭

## 安装

**下载** —— 从 [Releases](https://github.com/MuQY1818/Open-Yoink/releases) 获取 `OpenYoink-x.y.dmg`，打开后把 OpenYoink 拖进 Applications：

<p align="center">
  <img src="docs/screenshots/dmg-installer.png" width="330" alt="拖到 Applications 安装">
</p>

当前为 ad-hoc 签名（未公证）。首次打开请**右键 → 打开**，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/OpenYoink.app
```

新版本会自动送达：OpenYoink 检查 GitHub Pages 上的更新 feed，从 GitHub Releases 下载签名更新包（菜单栏菜单 →「检查更新…」可手动触发；「设置 → 通用」可关闭自动检查）。

**从源码构建** —— 需要 macOS 26+ 与 Xcode 26+。

```bash
git clone https://github.com/MuQY1818/Open-Yoink.git
cd Open-Yoink
open Open-Yoink.xcodeproj        # 或命令行构建：
xcodebuild -project Open-Yoink.xcodeproj -scheme OpenYoink -destination 'platform=macOS' build
```

`DEVELOPMENT_TEAM` 留空为本地签名运行；分发请填自己的团队。`Scripts/make-dmg.sh` 生成 DMG，`Scripts/notarize.sh` 说明公证流程。

## 使用

| 操作 | 方式 |
|---|---|
| 显示 / 隐藏暂存架 | ⌘⇧Space、菜单栏菜单、单击边缘拉环 |
| 剪贴板存入暂存架 | 双击 ⌘⇧Space |
| 添加内容 | 把任意内容拖到暂存架（或拖到拉环上） |
| 移动而非引用 | 按住 ⌘ 拖入 |
| Quick Look | 空格或双击卡片 |
| 移除项目 | 悬停 ✕、Delete 键或右键菜单 |
| 收起暂存架 | 点击暂存架内缘的小箭头 |
| 调整位置 | 沿屏幕边缘拖动拉环 / 推向对侧换边，或在设置中选择 |

设置（菜单栏 → 设置…）：位置与宽度、自动隐藏、拖出后策略（保留 / 移除 / 询问）、触发方式（快捷键、拖拽唤出、摇动三档灵敏度）、忽略的应用、语言。

## 架构

SwiftUI 负责渲染，AppKit 负责窗口、拖放与全局事件。

```
表现层    SwiftUI  ShelfView / 卡片 / Stack / 设置 / 菜单栏
窗口与IO  AppKit   NSPanel 暂存架 · 边缘拉环 · 拖放协议
                   QLPreviewPanel · Carbon 热键 · NSEvent 监听
领域层    服务     ShelfStore（@Observable）· 拖入协调 · 拖出组装
                   BookmarkService · CutMoveService
数据层    模型     ShelfItem（Codable）· JSON + 安全书签
```

关键决策：引用优先（⌘ 剪切除外）、基于 `NSFilePromiseProvider` 的拖出双表示、原子写 + 防抖的 JSON 持久化、安全书签维持沙箱访问、对 Finder 只复制不移动的保守语义。

## 测试

```bash
xcodebuild -project Open-Yoink.xcodeproj -scheme OpenYoink -destination 'platform=macOS' test
```

328 个单元测试覆盖数据层、持久化、书签、拖出组装、粘贴板兜底、触发器与布局。`TestFixtures/` 附带样例文件与浏览器上传测试页 `upload-test-page.html`，可在 Safari / Chrome / Firefox 中做拖出回归。

## Roadmap

- **v2** —— 剪贴板历史（可选开启，含隐私过滤）
- **v3** —— Handoff 与连续互通相机、系统扩展（Services / Quick Action / Share / Shortcuts）

明确不做：云同步、自动删除用户文件、「保证所有网站可上传」。

## 参与贡献

欢迎 Issue 与 PR。请遵循既有架构约定（拖放与窗口归 AppKit、纯逻辑可单测），提交前跑通测试。

## 致谢

OpenYoink 是净室实现：研究了多款 MIT 开源 shelf 应用的公开可观察行为，不包含这些项目的代码或素材。应用内唯一的第三方代码是 [Sparkle](https://github.com/sparkle-project/Sparkle)（MIT），用于自动更新。「Yoink」是 Eternal Storms Software 的产品，OpenYoink 与其无任何隶属关系。完整记录见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可证

[MIT](LICENSE) © 2026 weijue
