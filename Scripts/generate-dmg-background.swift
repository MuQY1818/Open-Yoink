#!/usr/bin/env swift
//
// generate-dmg-background.swift — 生成 DMG 安装窗口背景图（自绘，无第三方资源）。
//
// 运行：swift Scripts/generate-dmg-background.swift
// 产物：Scripts/dmg-background.png（660×440 px —— 必须与窗口 pt 尺寸 1:1：
//   Finder 按图片像素尺寸以 pt 为单位铺背景，@2x 会放大一倍导致元素出界）。
//   为兼顾 Retina 观感，全部内容先在 2x 离屏画布绘制再降采样到 1x
//   （超采样抗锯齿，文字不发虚）。
//
// 布局约定（与 make-dmg.sh 的 Finder 布局参数一致，单位均为 1x pt/px）：
//   窗口内容 660×440；app 图标中心 (160, 250)、Applications 别名中心
//   (500, 250)、图标 128pt；标题/副标题/点状箭头烘焙在背景图里。
//   NSGraphicsContext 原点左下：y = H - 距顶距离。

import AppKit

// 1x 输出尺寸与 2x 超采样因子。
let W: CGFloat = 660
let H: CGFloat = 440
let SS: CGFloat = 2

func makeRep(_ w: CGFloat, _ h: CGFloat) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(w), pixelsHigh: Int(h),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Failed to create bitmap rep \(Int(w))x\(Int(h))") }
    return rep
}

let big = makeRep(W * SS, H * SS)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: big)
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: SS, y: SS)  // 之后一律用 1x 坐标书写（原点左下）

// 1. 背景：近白微渐变（上白下浅灰）。
let bg = NSGradient(colors: [
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
    NSColor(srgbRed: 0.95, green: 0.96, blue: 0.975, alpha: 1.0),
])!
bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// 2. 标题：大号细字重（优雅风格，超采样后依然锐利）。
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 40, weight: .light),
    .foregroundColor: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1.0),
]
let title = NSAttributedString(string: "OpenYoink", attributes: titleAttrs)
let titleSize = title.size()
title.draw(at: NSPoint(x: (W - titleSize.width) / 2, y: H - 66 - titleSize.height))

// 3. 副标题：小号常规字重，中性灰。
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor(srgbRed: 0.44, green: 0.47, blue: 0.52, alpha: 1.0),
]
let subtitle = NSAttributedString(string: "拖至 Applications 完成安装 · Drag to Applications to install", attributes: subAttrs)
let subSize = subtitle.size()
subtitle.draw(at: NSPoint(x: (W - subSize.width) / 2, y: H - 104 - subSize.height))

// 4. 引导箭头：点状虚线 + 实心箭头头部，灰蓝色，位于图标行（距顶 250 → y=190）。
let arrowY: CGFloat = H - 250
let startX: CGFloat = 252   // app 图标右缘 224 → 留 28pt
let endX: CGFloat = 408     // Applications 左缘 436 → 留 28pt
let dotColor = NSColor(srgbRed: 0.4, green: 0.52, blue: 0.76, alpha: 0.95)

dotColor.setFill()
var x = startX
while x <= endX - 40 {
    ctx.fillEllipse(in: CGRect(x: x, y: arrowY - 3, width: 6, height: 6))
    x += 17
}

let head = NSBezierPath()
head.move(to: NSPoint(x: endX, y: arrowY))
head.line(to: NSPoint(x: endX - 22, y: arrowY - 13))
head.line(to: NSPoint(x: endX - 22, y: arrowY - 5))
head.line(to: NSPoint(x: endX - 32, y: arrowY - 5))
head.line(to: NSPoint(x: endX - 32, y: arrowY + 5))
head.line(to: NSPoint(x: endX - 22, y: arrowY + 5))
head.line(to: NSPoint(x: endX - 22, y: arrowY + 13))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

// 5. 超采样降落到 1x 画布（高质量插值）。
let final = makeRep(W, H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: final)
NSGraphicsContext.current!.imageInterpolation = .high
big.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()

guard let png = final.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode PNG")
}
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let outputURL = scriptURL.deletingLastPathComponent().appendingPathComponent("dmg-background.png")
do {
    try png.write(to: outputURL)
    print("wrote \(outputURL.path) (\(Int(W))x\(Int(H))px, supersampled \(Int(SS))x)")
} catch {
    fatalError("Failed to write PNG: \(error.localizedDescription)")
}
