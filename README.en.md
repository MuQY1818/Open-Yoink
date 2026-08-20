<div align="center">

<img src="OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="96" alt="OpenYoink icon">

# OpenYoink

**Drag it. Park it. Drop it later.**

A native drag-and-drop shelf for macOS. Park files, text, images, and links at the
edge of your screen or inside the Mac notch, then drag them out wherever they belong.

<br>

[![Latest release](https://img.shields.io/github/v/release/MuQY1818/OpenYoink?display_name=tag&sort=semver&style=flat-square)](https://github.com/MuQY1818/OpenYoink/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/MuQY1818/OpenYoink/total?style=flat-square)](https://github.com/MuQY1818/OpenYoink/releases)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://www.swift.org/)
[![MIT license](https://img.shields.io/github/license/MuQY1818/OpenYoink?style=flat-square)](LICENSE)

[Download](https://github.com/MuQY1818/OpenYoink/releases/latest) ·
[Website](https://muqy1818.github.io/OpenYoink/) ·
[Guide](https://muqy1818.github.io/OpenYoink/en/guide/) ·
[中文](README.md)

</div>

<br>

<a href="https://muqy1818.github.io/OpenYoink/">
  <img src="docs/images/banner.jpg" width="100%" alt="OpenYoink — Drag it. Park it. Drop it later.">
</a>

> [!NOTE]
> The current stable release is **v1.6.1**, adding a modular five-position Island, an in-Island module library, side-tab hover preview, and a read-only Mac system status module. See the [guide](https://muqy1818.github.io/OpenYoink/en/guide/) for the complete walkthrough.

## The problem it solves

When you move something between Finder, a browser, Mail, and other apps, the destination is often buried behind another window or Space. OpenYoink gives the content a temporary parking spot: drag it to a screen edge or the Mac notch, switch windows, and continue the drag to its destination.

OpenYoink lives in the menu bar without a Dock icon. It appears when you need it and gets out of the way when you are done.

## Highlights

- **Accepts everyday content:** files, folders, plain and rich text, images, links, plus mail messages, calendar events, contacts, and more.
- **Appears your way:** automatically when dragging, from an edge tab, with a global shortcut, or after a mouse-shake gesture.
- **Two independent entrances:** the classic side shelf and OpenYoink Island can run on their own or together and share the same parking space.
- **Native Island:** enabled by default for new installs and blended into the Mac camera housing; external and notchless displays fall back to a top pill with shelf, transfer, timer, battery, and Now Playing modules. It can be disabled independently.
- **Organizes without interruption:** Quick Look, multi-select, marquee selection, stacks, manual ordering, and recent items.
- **Works across your desktop:** multiple displays, Spaces, and full-screen apps, with a per-app ignore list.
- **Predictable file semantics:** source files are referenced by default and Finder drops only request a copy. Hold `⌘` while importing to use the managed-move flow described in [File safety and lifecycle](#file-safety-and-lifecycle).
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

| Action               | How                                                        |
| -------------------- | ---------------------------------------------------------- |
| Show / hide          | `⌘⇧Space`, the menu bar item, or click the screen edge tab |
| Add content          | Drop onto the shelf or the edge tab                        |
| Move instead of copy | Hold `⌘` while importing a file or folder                  |
| Park clipboard       | Press `⌘⇧Space` twice                                      |
| Quick Look           | Select a card and press `Space`, or double-click           |
| Multi-select         | Hold `⌘` and click, or marquee-select an empty area       |
| Remove               | Hover and click `×`, press `Delete`, or use the context menu |
| Reposition           | Drag the edge tab, or pick a position in Settings          |
| Enable / disable Island | Settings → General → OpenYoink Island                    |

## Supported content

| Content                          | How OpenYoink handles it                                  |
| -------------------------------- | --------------------------------------------------------- |
| Files and folders                | Keeps a sandbox bookmark to the original location         |
| Plain text and links             | Stored directly in the shelf data                         |
| Images, HTML, RTF                | Materialised into files in the app sandbox                |
| Contacts, events, mail messages  | Saved as `.vcf`, `.ics`, `.eml` when the source provides them |

When dropping a regular file, OpenYoink exposes the file URL with a Chromium-compatible filename so Finder, Safari, and most Chromium upload fields accept it. Managed-move drops use a confirmed file promise and only leave the shelf after the destination confirms the write. The destination always has the final say.

## File safety and lifecycle

- **Regular import** keeps a reference to the original location. Removing a card or choosing "remove after drop" never deletes the original file. If the file is moved, deleted, or its disk is offline, the card becomes unavailable until the bookmark resolves again.
- **Hold `⌘` while importing** and OpenYoink copies the file into the sandbox-managed folder, confirms the copy, then moves the original to the Trash. Any failure leaves the original in place and falls back to a regular reference. The original is only recoverable while the Trash is not yet emptied.
- **Managed-move drops** remove the shelf card and the sandbox copy only after the destination confirms receipt, regardless of the regular "after drop" policy. A failed or cancelled drop keeps the card and the copy for retry.
- **Text and links** live with the card and are cleared when you remove it. Materialised files lose their reference once the card is removed (manually or by policy) and are cleaned up on the next launch; you can also clear them on demand in **Settings → Storage**.

## Privacy by design

- App Sandbox is enabled. Shelf data and materialised files live in `Application Support/OpenYoink` and can be opened or pruned from **Settings → Storage**.
- No accounts. No analytics or telemetry. Normal use does not require Accessibility or Input Monitoring permissions. File access comes only from what you actively drag in.
- Automatic update checks are on by default and can be turned off. They talk only to GitHub Pages / Releases; there is no other background network activity.
- The current clipboard is read only when you explicitly press the double-tap shortcut to park it.
- **Now Playing** is an opt-in Island module. When enabled, it shows the real cover, progress, and media controls using a bundled helper when available, otherwise Apple Music / Spotify AppleScript with a possible Automation prompt. It does not use the network and a failure never affects the shelf or other Island modules.
- Persistence uses security-scoped bookmarks and atomic JSON writes to avoid extra copies of originals and to recover cleanly from partial writes.

## Build from source

You need macOS 15+ and Xcode 26+.

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
  test \
  -only-testing:OpenYoinkTests
```

Local builds do not require a `DEVELOPMENT_TEAM`. SwiftUI renders the interface, AppKit owns the windows, drag-and-drop, and global events. The tests cover persistence, drop-in / drop-out, shortcuts, triggers, and layout.

Maintainers can use [`Scripts/make-release.sh`](Scripts/make-release.sh) to produce a Developer ID + notarised release build, or pass `--adhoc` to produce a free community build. The script never silently falls back to a less secure signing mode.

## Contributing

Issues and pull requests are welcome.

- **Bug reports** should include macOS version, OpenYoink version, reproduction steps, and expected behaviour.
- **Larger changes** should open an issue first so we agree on scope before code lands.
- **Before submitting**, please run the full test suite and keep the change focused with a clear description.

## Roadmap

- [ ] Optional clipboard history with privacy filters
- [ ] Handoff and deeper system integration

> The roadmap signals intent, not commitments. Priorities shift with stability needs and user feedback.

## Credits and license

OpenYoink is an independent open-source implementation. It is not affiliated with, endorsed by, or derived from the commercial Yoink app. Automatic updates are powered by [Sparkle](https://sparkle-project.org/).

Third-party components and licenses are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). The project is released under the [MIT License](LICENSE).

<br>

<div align="center">

© 2026 weijue · MIT License

</div>
