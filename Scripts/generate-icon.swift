#!/usr/bin/env swift
//
// generate-icon.swift — 程序化生成 OpenYoink AppIcon（S10）。
//
// 运行：swift Scripts/generate-icon.swift（仓库根目录任意位置均可，路径按
// 脚本位置解析）。可重复运行：1024px 主图由 AppKit 矢量绘制，各尺寸经 sips
// 重采样，Contents.json 每次重写，产物直接入库到
// OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset/。
//
// 设计：macOS Big Sur+ 图标网格（824pt 圆角矩形居中于 1024 画布）+
// 蓝色纵向渐变底 + 白色「tray + 向下箭头」图形，与菜单栏 SF Symbol
// `tray.and.arrow.down.fill` 风格呼应。

import AppKit

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = repoRoot
    .appendingPathComponent("OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset")

// MARK: - Drawing

let canvas: CGFloat = 1024
let artInset: CGFloat = 100
let artRect = NSRect(x: artInset, y: artInset,
                     width: canvas - artInset * 2, height: canvas - artInset * 2)
let artCornerRadius = artRect.width * 0.2257  // ≈186pt，延续 macOS 图标曲率

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    fatalError("Failed to create bitmap rep")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

// 1. 渐变底（上浅下深的蓝色，顶光感）。
let roundedPath = NSBezierPath(roundedRect: artRect,
                               xRadius: artCornerRadius, yRadius: artCornerRadius)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.68, blue: 1.00, alpha: 1.0),
    NSColor(srgbRed: 0.05, green: 0.39, blue: 0.92, alpha: 1.0),
])!
gradient.draw(in: roundedPath, angle: -90)

// 2. 顶部轻高光（很薄的白色渐变，增加层次但不破坏扁平感）。
context.saveGState()
roundedPath.addClip()
let gloss = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.14),
    NSColor.white.withAlphaComponent(0.0),
])!
gloss.draw(from: NSPoint(x: artRect.midX, y: artRect.maxY),
           to: NSPoint(x: artRect.midX, y: artRect.maxY - artRect.height * 0.42),
           options: [])
context.restoreGState()

// 3. 白色 tray + 向下箭头（线宽、圆角端点/拐角与 SF Symbol 风格一致）。
let glyphColor = NSColor.white.withAlphaComponent(0.97)
glyphColor.setStroke()
let strokeWidth: CGFloat = 56

let tray = NSBezierPath()
tray.lineWidth = strokeWidth
tray.lineCapStyle = .round
tray.lineJoinStyle = .round
tray.move(to: NSPoint(x: 342, y: 500))            // 左壁顶
tray.line(to: NSPoint(x: 342, y: 356))
tray.curve(to: NSPoint(x: 400, y: 298),           // 左下圆角
           controlPoint: NSPoint(x: 342, y: 298))
tray.line(to: NSPoint(x: 624, y: 298))            // 底边
tray.curve(to: NSPoint(x: 682, y: 356),           // 右下圆角
           controlPoint: NSPoint(x: 682, y: 298))
tray.line(to: NSPoint(x: 682, y: 500))            // 右壁顶
tray.stroke()

let arrow = NSBezierPath()
arrow.lineWidth = strokeWidth
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 512, y: 748))           // 箭杆
arrow.line(to: NSPoint(x: 512, y: 472))
arrow.move(to: NSPoint(x: 430, y: 552))           // 箭头左翼
arrow.line(to: NSPoint(x: 512, y: 464))
arrow.line(to: NSPoint(x: 594, y: 552))           // 箭头右翼
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()

// MARK: - Output

guard let png1024 = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode 1024px PNG")
}

let fileManager = FileManager.default
try? fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let masterURL = iconsetURL.appendingPathComponent("AppIcon-1024.png")
do {
    try png1024.write(to: masterURL)
    print("wrote \(masterURL.path)")
} catch {
    fatalError("Failed to write master PNG: \(error.localizedDescription)")
}

// 各尺寸经 sips 重采样（高质量 LANCZOS）。
let sizes = [16, 32, 64, 128, 256, 512]
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
