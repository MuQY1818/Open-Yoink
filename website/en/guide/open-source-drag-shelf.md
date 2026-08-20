---
title: A free, open-source drag shelf for macOS
description: Learn how OpenYoink temporarily holds files, images, text, and links while you move them across macOS windows, Spaces, and full-screen apps.
---

# A free, open-source drag shelf for macOS

OpenYoink is a free, open-source, local-first drag-and-drop shelf for macOS. It solves a specific problem: the destination window is often hidden when you start dragging something. Instead of holding the mouse while rearranging windows, park the file, folder, image, text, or link in OpenYoink, switch to the destination, and drag it out again.

The app is built with SwiftUI and AppKit and released under the MIT License. It requires no account or subscription, contains no behavioral analytics, and supports macOS 15 on both Apple Silicon and Intel Macs.

## When is a drag shelf useful?

### Moving files between Finder and a browser

An upload page often covers the Finder window containing the file you need. OpenYoink turns one fragile, continuous drag into two short actions: park the file, reveal the browser, and drag it into the upload target.

### Dragging across Spaces and full-screen apps

Keeping a file attached to the pointer while changing Spaces can be awkward. OpenYoink holds the item while you navigate normally, then lets you resume the drag from the destination desktop.

### Collecting several items before using them

Files and links from different apps can share one temporary shelf. Once the collection is ready, you can drag items out, copy their paths, or reveal them in Finder without creating a permanent organization folder first.

### Turning the Mac notch into a useful surface

OpenYoink Island integrates with the camera area on notched Macs. Its modules cover the Shelf, transfers, focus timer, battery, and Now Playing. Displays without a notch use a floating top capsule, and the classic edge shelf remains available if you do not want the Island.

## How is OpenYoink different from the clipboard?

| Tool | Best suited for | Preserves drag-and-drop |
|---|---|---|
| System clipboard | Copying text or a few files | No, the workflow is primarily copy and paste |
| OpenYoink shelf | Continuing a drag across windows, Spaces, and apps | Yes, items can be dragged into compatible targets |
| Finder folder | Long-term storage and organization | Yes, but it requires choosing a permanent location |

OpenYoink is not cloud storage or a long-term file manager. It is a temporary landing spot that stays under your control.

## Use the classic shelf, the Island, or both

The classic edge shelf and OpenYoink Island are independent surfaces backed by the same shelf contents. You can enable either one, use both at once, or disable the Shelf module inside the Island while keeping the edge shelf active.

See [OpenYoink Island](./island) for the top-surface workflow and the [quick start](./quick-start) for your first drag.

## Local-first file handling

OpenYoink does not upload shelf contents to a server. Ordinary drops generally retain a reference to the original item; explicitly managed move operations may create an app-managed copy. Read [File safety](./file-safety) before using managed moves with important files.

## Relationship to Yoink and Dropover

OpenYoink is an independent community project and is not affiliated with the commercial Yoink or Dropover apps or their developers. Those names are mentioned only to describe the product category for people looking for a free, open-source macOS drag-and-drop utility.

## Download OpenYoink

Install OpenYoink with Homebrew or download the latest build from [GitHub Releases](https://github.com/MuQY1818/OpenYoink/releases/latest). Then follow the [quick start](./quick-start) and review the [file-safety model](./file-safety).

Bug reports and compatibility details are welcome in [GitHub Issues](https://github.com/MuQY1818/OpenYoink/issues).
