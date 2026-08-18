<p align="center">
  <img src="OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="96" alt="OpenYoink icon">
</p>

<h1 align="center">OpenYoink</h1>

<p align="center">
  A native macOS drag-and-drop shelf: park files, text, images and links at the edge of your screen, then drop them wherever they go.<br>
  <a href="README.md">中文</a> · <a href="#install">Install</a> · <a href="#usage">Usage</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-blue" alt="platform">
  <img src="https://img.shields.io/badge/swift-6-orange" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/tests-328%20passing-brightgreen" alt="tests">
</p>

The shelf slides out when you start dragging — drop things on it, navigate anywhere hands-free, then drag them back out. Lives in the menu bar, no Dock icon.

## Features

- Drag in: files & folders, text, rich text, images, links — plus mail, calendar events, contacts (materialized as files)
- Drag out: dual `fileURL` + file promise representation, works with browser upload zones; Finder drops are always copies
- Hold ⌘ while dropping to move the original into the shelf (goes to the Trash, recoverable)
- Appears on drag / edge tab / ⌘⇧Space (double-press saves the clipboard) / mouse shake; per-app ignore list
- Quick Look, multi-select, stacks, marquee selection, manual ordering, recent items
- Multi-display, multi-Space and full-screen aware; English & Chinese UI
- Private: App Sandbox, no analytics; network only for update checks (can be disabled)

## Install

```bash
brew install --cask muqy1818/tap/openyoink
```

Homebrew installs skip the Gatekeeper prompt. Or grab the DMG from [Releases](https://github.com/MuQY1818/OpenYoink/releases) and drag OpenYoink to Applications — it's ad-hoc signed, so on first launch run:

```bash
xattr -dr com.apple.quarantine /Applications/OpenYoink.app
```

(Or System Settings → Privacy & Security → Open Anyway.) Later versions arrive via Sparkle auto-update.

## Usage

<p align="center">
  <img src="docs/images/usage-demo.gif" width="640" alt="Dragging files into the shelf">
</p>

| Action | How |
|---|---|
| Show / hide | ⌘⇧Space, menu-bar menu, or click the edge tab (click the same spot to collapse) |
| Add | Drag anything onto the shelf or the tab |
| Move instead of reference | Hold ⌘ while dropping |
| Quick Look | Space or double-click a card |
| Remove | Hover ✕, Delete key, or context menu |
| Reposition | Drag the tab along the edge, or use Settings |

Settings (menu bar → Settings…): position & width, auto-hide, drag-out policy, triggers & sensitivities, ignored apps, language.

## Build from source

Requires macOS 26+ and Xcode 26+.

```bash
git clone https://github.com/MuQY1818/OpenYoink.git
cd Open-Yoink
xcodebuild -project Open-Yoink.xcodeproj -scheme OpenYoink -destination 'platform=macOS' build
xcodebuild -project Open-Yoink.xcodeproj -scheme OpenYoink -destination 'platform=macOS' test
```

SwiftUI renders; AppKit owns windows, drag & drop and global events. Reference-based storage with security-scoped bookmarks, atomic JSON persistence. Leave `DEVELOPMENT_TEAM` empty for local signing. Release/DMG/notarization scripts live in `Scripts/`.

## Roadmap

- v2: clipboard history (opt-in, with privacy filters)
- v3: Handoff and system extensions

## Acknowledgments & License

Clean-room implementation — studied the public behavior of several MIT-licensed shelf apps without copying code; bundles Sparkle (MIT) for updates. Full record in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

[MIT](LICENSE) © 2026 weijue
