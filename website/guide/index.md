---
title: OpenYoink 使用文档
description: 从安装、第一次拖放，到 Island、文件安全和常见问题。
---

# OpenYoink 使用文档

OpenYoink 是一个常驻菜单栏的 macOS 拖拽暂存架。当目标窗口暂时不在眼前时，把文件、文本、图片或链接先放进 OpenYoink，切换窗口后再把它拖到最终位置。

## 第一次使用，从这里开始

1. [安装 OpenYoink](./install)：选择 Homebrew 或 GitHub Release，并处理首次启动提示。
2. [三分钟快速上手](./quick-start)：完成第一次拖入、切换窗口和拖出。
3. [认识文件安全边界](./file-safety)：弄清“普通引用”与“按住 ⌘ 托管移动”的区别。

## 选择你的工作方式

| 方式 | 适合场景 | 是否共享内容 |
|---|---|---|
| [侧边暂存架](./classic-shelf) | 拖放优先、希望有更大的内容区域 | 是 |
| [OpenYoink Island](./island) | 有刘海的 Mac、希望把顶部区域用于轻量活动 | 是 |
| 两者同时开启 | 既需要快速拖放，也希望保留顶部信息中心 | 是 |

侧边暂存架和 Island 是两个独立入口，但它们读取同一个暂存空间。你可以只开一个，也可以同时开启；关闭 Island 的“暂存架”模块，也不会关闭侧边暂存架。

::: tip v1.5.0 已发布
当前稳定版新增 Flow 风格专注计时、专注记录热力图、Island 显示器选择与展开态设置入口。暂存架、传输、电池和可选的“正在播放”模块继续共享同一套 Island 平台。
:::

## 需要帮助？

- 应用打不开、更新失败或拖不进去：查看[常见问题](./troubleshooting)。
- 想确认某个操作会不会删除原文件：查看[文件安全与隐私](./file-safety)。
- 发现 Bug：前往 [GitHub Issues](https://github.com/MuQY1818/OpenYoink/issues)，附上 macOS 版本、OpenYoink 版本与复现步骤。
