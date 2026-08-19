---
title: File safety
---

# File safety

Ordinary files and folders are referenced with security-scoped bookmarks; OpenYoink does not duplicate or delete the original. Removing a normal shelf card never deletes its source file.

Holding `⌘` while dropping starts a managed move: OpenYoink copies the item into its sandbox, verifies the copy, and only then moves the original to Trash. Any failure keeps the original and falls back to a normal reference. A delivered managed item is removed from the shelf together with its managed copy.

OpenYoink requires no account and contains no analytics or telemetry. Its normal background network activity is the optional update check against GitHub Pages and Releases.

