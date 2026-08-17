# Open-Yoink

一个**开源、原生、简洁**的 macOS 拖拽暂存工具：把文件、文本、图片、链接先放进屏幕边缘的「暂存架（shelf）」，切换到目标窗口后再一次性拖出去。

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License MIT](https://img.shields.io/badge/license-MIT-blue)
![Tests 296 passing](https://img.shields.io/badge/tests-296%20passing-brightgreen)

> 灵感来自 Yoink（Eternal Storms Software 的商业产品）。Open-Yoink 是独立的清洁实现，与其无任何隶属关系。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

<!-- SCREENSHOTS: 待真机验收后补充 -->

## 功能

**暂存与拖放**
- 拖入 Finder 文件/文件夹、文本、图片、URL、file promise，只保存引用、不复制原文件。
- 拖出到任意目标：文件同时提供 `fileURL` 与 file promise 双表示，对浏览器上传区做最佳努力兼容（不承诺所有网站均可上传）。
- 拖入双模式：直接拖入 = 复制引用；**⌘ + 拖入 = 剪切移入保管**，原文件移入废纸篓（可恢复），交付确认后才清理保管副本。

**触发方式**
- 全局快捷键（默认 **⌘⇧Space**，可自定义；**双击存剪贴板**到 shelf，可关）。
- 拖动开始自动出现：立即 / 仅拖拽贴边 / 关闭 三档（默认立即）。
- 可选鼠标摇动触发（默认关）、EdgeTab 边缘拉环（默认开）。

**操作与组织**
- Quick Look：空格 / 双击 / 多选预览。
- 右键菜单：Quick Look / 打开 / 在 Finder 显示 / 移除（不删原文件）；卡片悬停 ✕ 快速移除。
- 多选（⌘ 点击 / 框选）、批量拖出、Stack 合并与展开、手动排序。
- 拖出后策略：保留 / 移除 / 每次询问。

**系统融合**
- 菜单栏 agent 运行（`LSUIElement`，无 Dock 图标）；最近项目菜单。
- shelf 面板：左 / 右 / 自定义位置，宽度可调，紧凑高度贴合内容，空架自动隐藏。
- 多屏 / 多 Space / 全屏：跟随鼠标所在屏幕，跨 Space 保持可用。
- 中英文界面（跟随系统语言，可在设置中覆盖）；忽略应用列表。

**隐私**
- App Sandbox、不联网、不请求辅助功能（Accessibility）权限。

### v1 明确不做

剪贴板历史（v2）；Handoff / Continuity / iOS 伴侣（v3）；云同步等外部服务；Services / Share / Shortcuts 等系统扩展（v3）；自定义 Quick Look 扩展；任何情况下自动删除用户原文件。

## 使用

1. **唤出 shelf**：按 ⌘⇧Space，或点击屏幕边缘的 EdgeTab 拉环，或直接开始拖动一个文件（默认立即出现）。
2. **拖入暂存**：把文件 / 文本 / 图片 / 链接拖进 shelf。按住 ⌘ 拖入则为剪切移入保管（原文件进废纸篓，可在废纸篓恢复）。
3. **拖出交付**：从 shelf 把项目拖到目标位置（Finder、浏览器上传区、聊天、邮件附件等）。
4. **EdgeTab**：shelf 隐藏时屏幕边缘常驻小拉环——单击展开、拖文件可直接投放、沿边拖动调整上下位置、推向对侧换边；可在设置中关闭。
5. **快捷键**：⌘⇧Space 唤出 / 隐藏；**双击**该快捷键把当前剪贴板内容存入 shelf（可在设置关闭，关闭后单击零延迟）；快捷键可自定义录制。
6. **预览与整理**：空格或双击 Quick Look；⌘ 点击或框选多选；多选可合并为 Stack、批量拖出；拖动卡片手动排序。
7. **设置**：菜单栏 → Settings，含 General（位置 / 宽度 / 自动隐藏 / 拖出后策略 / 语言）、Triggers（快捷键 / 摇动 / 拖动出现档位）、Ignored Apps、About 四页。

## 系统要求

- macOS 26 (Tahoe) 或更高版本
- 构建需 Xcode 26+ / Swift 6+

## 构建

用 Xcode 打开工程直接运行：

```bash
git clone https://github.com/<you>/Open-Yoink.git
cd Open-Yoink
open Open-Yoink.xcodeproj
```

或用命令行：

```bash
# 构建（Debug）
xcodebuild build -project Open-Yoink.xcodeproj -scheme OpenYoink -configuration Debug

# 运行全部单元测试（296 例）
xcodebuild test -project Open-Yoink.xcodeproj -scheme OpenYoink -destination 'platform=macOS'

# Release 归档（产物在 export/，该目录已在 .gitignore 中）
xcodebuild archive -project Open-Yoink.xcodeproj -scheme OpenYoink -configuration Release -archivePath export/OpenYoink.xcarchive
```

应用以菜单栏 agent 运行（无 Dock 图标）。

**签名说明**：工程 `DEVELOPMENT_TEAM` 默认为空，构建产物为「本地签名（ad hoc / Sign to Run Locally）」，可直接在本机运行与归档。个人开发者如需对外分发，请在 Xcode 的 Signing & Capabilities 中填入自己的 Team（不要提交该改动到仓库）。

## 分发与 quarantine

当前发布版本为本地签名、**未经 Apple 公证**。从网络下载的副本首次打开时，Gatekeeper 可能提示无法验证开发者。可选做法：

- 在 Finder 中**右键点击 OpenYoink.app → 打开**，再在对话框中确认；或
- 执行 `xattr -dr com.apple.quarantine /path/to/OpenYoink.app` 移除隔离属性。

这两种方式都只是告诉 macOS「信任这个你主动获取的副本」，是否使用由你自行判断。计划公证分发时，可参考 `Scripts/notarize.sh`（占位脚本，含 notarytool 完整命令与凭据变量说明，填入自己的 Apple Developer 信息即可启用）。

## 手动测试

单元测试覆盖不了的跨应用拖放链路，提供手动验证材料（不入包、不上架）：

- `TestFixtures/upload-test-page.html`：自建浏览器上传测试页，用 Safari / Chrome / Firefox 打开后从 shelf 拖文件到上传区，验证 `fileURL` + file promise 链路。
- `TestFixtures/sample-files/`：文本 / Markdown / PNG 样例文件，用于拖入拖出与 Quick Look 冒烟测试。

## 架构

四层结构，SwiftUI 渲染、AppKit 管窗口与拖放：

```
Presentation (SwiftUI)      ShelfView / ItemCard / StackView / SettingsView
Window & Interaction        ShelfPanel(NSPanel) / DragSource / QuickLook / HotKey / Shake / EdgeTab
Domain / Service            ShelfStore(@Observable) / DragPayloadBuilder / FilePromise / Bookmark / CutMove
Data                        ShelfItem(Codable) / JSON + security-scoped bookmark / SettingsStore(UserDefaults)
```

关键决策：

- **拖放走 AppKit**：跨应用拖放的 pasteboard 控制、file promise、窗口 level / collectionBehavior 一律用 `NSDraggingSource/Destination`，不依赖 SwiftUI 的 `onDrag/onDrop`。
- **状态用 `@Observable`**（Observation framework），SwiftUI 经 `@Environment` 注入，AppKit 侧显式持有。
- **持久化用 JSON + security-scoped bookmark**：原子写入 + 500ms 防抖；bookmark 失效标记 stale 而非静默删除。数据在沙箱容器 `~/Library/Containers/com.weijue.OpenYoink/Data/Library/Application Support/OpenYoink/`。
- **全局快捷键用 Carbon `RegisterEventHotKey`**（无需 Accessibility），失败时回退 NSEvent 全局监听。
- **剪切用废纸篓而非删除**：⌘+拖入为 copy-verify-then-trash，原文件进废纸篓可恢复；任何代码路径都不会直接删除用户原文件。

## 隐私与权限

- 仅申请 App Sandbox + 用户选择文件读写 + security-scoped bookmark 三项 entitlement。
- 无任何网络请求，无遥测，无第三方 SDK。
- 不请求 Accessibility、Full Disk Access 等系统权限；摇动 / 边缘等触发均为纯轨迹启发式。
- 所有数据（shelf 项目、设置、保管副本）只存于上述沙箱容器内。

## Roadmap

- **v2**：剪贴板历史（含隐私过滤）。
- **v3**：Handoff / Continuity、Services / Share / Shortcuts 系统扩展、自定义 Quick Look 扩展。

## 许可证

[MIT](LICENSE) © weijue

---

## English

An open-source, native, minimal drag-and-drop shelf for macOS. Stage files, text, images and links on a shelf at the screen edge, then drag them out to any destination. See the Chinese section above for full documentation.
