<p align="center">
  <a href="https://muqy1818.github.io/OpenYoink/">
    <img src="OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="104" alt="OpenYoink icon">
  </a>
</p>

<h1 align="center">OpenYoink</h1>

<p align="center"><strong>Drag it. Park it. Drop it later.</strong></p>

<p align="center">
  A native drag-and-drop shelf for macOS. Park files, text, images, and links at the<br>
  edge of your screen, switch to the destination, then drag them back out.
</p>

<p align="center">
  <a href="https://github.com/MuQY1818/OpenYoink/releases/latest"><img src="https://img.shields.io/github/v/release/MuQY1818/OpenYoink?display_name=tag&sort=semver&style=flat-square" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 15+"><img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/MuQY1818/OpenYoink?style=flat-square" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/MuQY1818/OpenYoink/releases/latest">Download</a> ·
  <a href="#install">Install</a> ·
  <a href="https://muqy1818.github.io/OpenYoink/">Website</a> ·
  <a href="README.md">中文</a>
</p>

<p align="center">
  <img src="docs/images/usage-demo.gif" width="760" alt="Dragging files into the OpenYoink shelf">
</p>

## The problem it solves

When you move something between Finder, a browser, Mail, and other apps, the destination is often buried behind another window or Space. OpenYoink turns one awkward cross-window drag into three simple steps:

| 1. Park | 2. Navigate | 3. Drop |
|:---:|:---:|:---:|
| Start dragging and the shelf slides in | Switch windows, Spaces, or full-screen apps freely | Drag the item from the shelf to its destination |

OpenYoink lives in the menu bar without a Dock icon. It appears when needed and gets out of the way when you are done.

## Highlights

- **Accepts everyday content:** files, folders, plain and rich text, images, links, plus mail messages, calendar events, contacts, and more.
- **Appears your way:** automatically when dragging, from an edge tab, with a global shortcut, or after a mouse-shake gesture.
- **Organizes without interruption:** Quick Look, multi-select, marquee selection, stacks, manual ordering, and recent items.
- **Works across your desktop:** multiple displays, Spaces, and full-screen apps, with a per-app ignore list.
- **Uses predictable file semantics:** source files are referenced by default, and Finder drops only request a copy. Hold ⌘ while importing to use the managed-move flow described in [File safety and lifecycle](#file-safety-and-lifecycle).
- **Native and focused:** SwiftUI + AppKit, English and Chinese UI, launch at login, and Sparkle updates.

## Install

**Requires macOS 15 Sequoia or later.** Release builds target both Apple Silicon and Intel Macs.

### Homebrew (recommended)

```bash
brew install --cask muqy1818/tap/openyoink
```

The Homebrew cask downloads the matching GitHub Release DMG and removes this app's quarantine attribute after installation, so it normally avoids a Gatekeeper block. This does not change the package signature or make the build notarized by Apple. OpenYoink can check for later updates through Sparkle.

### Manual installation

1. Download the latest DMG from [GitHub Releases](https://github.com/MuQY1818/OpenYoink/releases/latest).
2. Open the DMG and drag OpenYoink into `Applications`.
3. If macOS blocks the first launch, right-click OpenYoink in Finder and choose **Open**, or allow it under **System Settings → Privacy & Security**.

> [!NOTE]
> Free community builds on GitHub Releases are ad-hoc signed but not notarized by Apple, so a first-time manual installation may trigger a system warning. Sparkle's EdDSA signature protects packages delivered by the updater; it does not replace verification of the first download or Apple notarization.

<details>
<summary>Still unable to open the app?</summary>

Use this only after confirming that the app came from the official OpenYoink Release URL above. You can first run `shasum -a 256 OpenYoink-VERSION.dmg` (replace `VERSION` with the release number) and compare it with the `sha256` for the same version in the [Homebrew cask](https://github.com/MuQY1818/homebrew-tap/blob/main/Casks/openyoink.rb). The command below explicitly bypasses Gatekeeper's quarantine check for this app:

```bash
xattr -dr com.apple.quarantine /Applications/OpenYoink.app
```

</details>

## Quick start

| Action | How |
|---|---|
| Show or hide the shelf | `⌘⇧Space`, the menu-bar menu, or the edge tab |
| Add content | Drag it onto the shelf or edge tab |
| Move instead of reference | Hold `⌘` while importing a file or folder |
| Save the current clipboard contents | Press `⌘⇧Space` twice |
| Quick Look | Select a card and press `Space`, or double-click it |
| Select multiple items | ⌘-click, or drag a marquee across empty shelf space |
| Remove an item | Use the hover `×`, press `Delete`, or open the context menu |
| Reposition the shelf | Drag the edge tab along the screen, or choose a position in Settings |

The menu-bar **Settings…** window also controls shelf width, auto-hide behavior, post-drag policy, trigger sensitivity, ignored apps, launch at login, storage management, and language. Regular items stay on the shelf after drag-out by default; this can be changed to remove them or ask every time.

## Supported content

| Content | How OpenYoink handles it |
|---|---|
| Files and folders | Keeps a sandbox bookmark to the original location by default; no shelf copy is created |
| Plain text and links | Stores them directly in the shelf data |
| Images, HTML, and RTF | Materializes them as files in the app's managed sandbox directory |
| Contacts, calendar events, and mail messages | Materializes `.vcf`, `.ics`, and `.eml` files when the source app exposes readable data |

When dragging files out, OpenYoink offers both file URLs and file promises for compatibility with Finder and common browser upload zones. Final acceptance still depends on the destination app or website.

## File safety and lifecycle

- **Regular file and folder imports** store a reference to the original location. Removing a card or choosing “remove after drag-out” never deletes that original. If it is moved, deleted, or on an offline volume, the card is marked unavailable until the bookmark can resolve again.
- **⌘-importing a file or folder** first copies it into the app's managed sandbox directory and verifies that copy before moving the original to the Trash. If either step fails, the original stays in place and OpenYoink falls back to a regular reference. Recovery is possible only while the Trash has not been emptied.
- **A managed-move item delivered successfully** is removed from the shelf and its managed copy is deleted after the destination receives the file. This does not follow the regular post-drag policy. A cancelled or failed delivery keeps both the item and managed copy so it can be retried.
- **Text and links** live in the shelf data and are removed with their card. Materialized images, rich text, mail messages, and similar content become unreferenced when their card is removed manually or by policy; those files are deleted during the safe cleanup on the next launch, or can be reviewed and cleaned immediately under **Settings → Storage**.

## Privacy and design

- App Sandbox is enabled. Shelf data and materialized files live under `Application Support/OpenYoink` inside the sandbox; **Settings → Storage** can reveal the data folder and clean unused files.
- No account is required, and there is no analytics or telemetry. Normal use does not require Accessibility or Input Monitoring permission; file access comes from content the user explicitly drags in.
- In the current version, automatic update checks are enabled by default and can be disabled in Settings. Automatic and manual checks contact GitHub Pages / Releases; the current version has no other background network feature.
- In the current version, OpenYoink reads the clipboard only when the user invokes the double-shortcut clipboard action.
- Persistence uses security-scoped bookmarks and atomic JSON writes to reduce unnecessary source-file copies and the risk of snapshot damage from partial writes.

## Build from source

Development requires macOS 15+ and Xcode 26+.

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

Local builds do not require a `DEVELOPMENT_TEAM`. SwiftUI renders the interface, while AppKit owns windows, drag and drop, and global events. The test suite covers persistence, import and delivery, shortcuts, triggers, and layout behavior.

Maintainers can use [`Scripts/make-release.sh`](Scripts/make-release.sh) to produce a Developer ID–signed and notarized release, or explicitly pass `--adhoc` for a free community build. The script never silently downgrades the signing mode after a failure.

## Contributing

Issues and pull requests are welcome.

- For bugs, include your macOS version, OpenYoink version, reproduction steps, and expected behavior.
- Please open an [issue](https://github.com/MuQY1818/OpenYoink/issues) before starting a large change so the intended direction is clear.
- Run the complete test suite before submitting code, and keep pull requests focused and well explained.

## Roadmap

- [ ] Optional clipboard history with privacy filters
- [ ] Handoff and deeper system integration

The roadmap describes areas of exploration, not promised versions or dates. Priorities may change as stability work and user feedback evolve.

## Acknowledgments and license

OpenYoink is an independent open-source implementation. It is not affiliated with, authorized by, or endorsed by the commercial Yoink app or its developer. Automatic updates are powered by [Sparkle](https://sparkle-project.org/).

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for bundled components and licenses. OpenYoink is released under the [MIT License](LICENSE).

© 2026 weijue
