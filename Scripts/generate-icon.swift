#!/usr/bin/env swift
//
// generate-icon.swift — 从主图重采样生成 OpenYoink AppIcon 全部槽位。
//
// 运行：swift Scripts/generate-icon.swift（仓库根目录任意位置均可，路径按
// 脚本位置解析）。可重复运行：以 Scripts/AppIcon-master.png 为主图
// （当前版本由项目作者以 AI 生成并人工选定），各尺寸经 sips 重采样，
// Contents.json 每次重写，产物直接入库到
// OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/。
//
// 如需更换图标：替换 Scripts/AppIcon-master.png（正方形 PNG，建议 ≥1024px）
// 后重新运行本脚本。

import AppKit

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let masterURL = repoRoot.appendingPathComponent("Scripts/AppIcon-master.png")
let iconsetURL = repoRoot
    .appendingPathComponent("OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: masterURL.path) else {
    fatalError("Master artwork missing: \(masterURL.path)")
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let output = iconsetURL.appendingPathComponent("AppIcon-\(size).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "\(size)", "\(size)", masterURL.path, "--out", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("sips failed for size \(size) (status \(process.terminationStatus))")
    }
    print("wrote \(output.path)")
}

// Contents.json：10 个槽位（512@2x 复用 1024 主图，依此类推）。
let contents = """
{
  "images" : [
    { "filename" : "AppIcon-16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "AppIcon-32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "AppIcon-32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "AppIcon-64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "AppIcon-128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "AppIcon-256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "AppIcon-256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "AppIcon-512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "AppIcon-512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "AppIcon-1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
do {
    try contents.write(to: iconsetURL.appendingPathComponent("Contents.json"),
                       atomically: true, encoding: .utf8)
    print("wrote Contents.json")
} catch {
    fatalError("Failed to write Contents.json: \(error.localizedDescription)")
}

print("AppIcon generation complete.")
