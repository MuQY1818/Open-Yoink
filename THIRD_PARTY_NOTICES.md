# Third-Party Notices & Clean-Implementation Record

Open-Yoink 是一个**清洁实现（clean-room implementation）**。我们参考了若干开源项目的**公开可观察行为与架构思路**，但没有复制其源代码、UI 素材或专有实现。本文件记录行为参考来源；如未来引入任何第三方代码或资源，会在此追加其许可证文本与版权归属。

## 行为参考（行为级研究，未复制代码）

| 项目 | 仓库 | 许可证 | 参考点 |
|---|---|---|---|
| HoldMac | https://github.com/Funnyrz/HoldMac | MIT | 文件引用式暂存、Finder 拖拽启发式触发思路 |
| DropKit | https://github.com/chenyuxiaojin/DropKit | MIT | shelf + 菜单栏产品结构、摇动召唤交互思路 |
| ShelfMate | https://github.com/stoimeniliev/shelfmate | MIT | NSPanel 窗口行为、摇动检测思路 |
| NotchPocket | https://github.com/ijashuzain/NotchPocket | MIT | NSPanel + NSItemProvider 拖放结构 |
| nab | https://github.com/jameshiew/nab | MIT-0 | 最小 shelf 生命周期与窗口行为 |
| Dropshit | https://github.com/iamsumanp/Dropshit | MIT | fileURL + NSFilePromiseProvider 多表示拖出思路 |

> ClipKit（GPL-3.0）仅作为剪贴板功能的行为参考，未复制其代码；Open-Yoink v1 不含剪贴板历史。

## 项目自有资源

- **App 图标**：`Scripts/AppIcon-master.png` 由项目作者使用 ChatGPT（AI 图像生成）创作并人工选定，版权归项目作者本人所有，随项目以 MIT 许可证发布；`Scripts/generate-icon.swift` 为项目自绘的重采样脚本，负责从主图生成 `Assets.xcassets` 全部槽位。
- 其余代码、界面、文案、本地化字符串均为项目原创。

## 当前版本确认声明

**Open-Yoink v1.0 未包含任何第三方代码、库、图片、字体或其他资源。** 上表所列项目仅为行为级参考，无任何代码或素材进入本仓库。如未来版本引入第三方代码或资源，将在此文件追加其许可证文本与版权归属。

## 商标声明

「Yoink」是 Eternal Storms Software 的产品名称。Open-Yoink 与其无任何隶属或授权关系，仅借鉴其公开描述的用户行为，不复制其代码、图标、文案或品牌资产。

## Apple 平台

本应用使用 Apple 公开 API（AppKit、SwiftUI、UniformTypeIdentifiers、Quick Look 等）开发，遵循 Apple Developer Program License Agreement。
