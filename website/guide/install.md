---
title: 安装 OpenYoink
description: 通过 Homebrew 或 GitHub Release 安装 OpenYoink，并处理首次启动提示。
---

# 安装 OpenYoink

## 系统要求

- macOS 15 Sequoia 或更高版本
- Apple Silicon 或 Intel Mac

## 使用 Homebrew 安装（推荐）

在“终端”中运行：

```bash
brew install --cask muqy1818/tap/openyoink
```

Homebrew cask 会下载官方 GitHub Release 的 DMG，并移除这个应用的隔离属性，因此通常不会出现 Gatekeeper 拦截。

::: warning 免费社区构建
OpenYoink 当前通过 GitHub 免费分发，使用 ad-hoc 签名，并未经过 Apple 公证。Homebrew 移除隔离属性不等于 Apple 公证，也不会改变应用签名。
:::

## 手动安装

1. 打开 [GitHub Releases](https://github.com/MuQY1818/OpenYoink/releases/latest)，下载最新 DMG。
2. 打开 DMG，把 OpenYoink 拖入“应用程序”。
3. 第一次启动若被 macOS 拦截，在 Finder 中右键 OpenYoink，选择“打开”。
4. 若仍无法打开，前往“系统设置 → 隐私与安全性”，确认允许打开。

![把 OpenYoink 拖入应用程序](/screenshots/dmg-installer.png)

### 仍然提示应用已损坏

先确认 DMG 来自官方 Release。然后可以在终端运行：

```bash
xattr -dr com.apple.quarantine /Applications/OpenYoink.app
```

这条命令只移除 `/Applications/OpenYoink.app` 的隔离属性。不要把路径改成整个“应用程序”目录。

## 启动后在哪里？

OpenYoink 是菜单栏应用，不显示 Dock 图标。启动后请在屏幕右上方菜单栏寻找 OpenYoink 图标，从那里可以打开暂存架和设置。

下一步：[完成第一次拖入与拖出](./quick-start)。

