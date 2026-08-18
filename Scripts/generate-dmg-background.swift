// generate-dmg-background.swift — 生成 DMG 安装窗口背景图（自绘，无第三方资源）。
//
// 运行：swift Scripts/generate-dmg-background.swift
// 产物：Scripts/dmg-background.png（600×360 px —— 必须与窗口 pt 尺寸 1:1：
//   Finder 按图片像素尺寸以 pt 为单位铺背景，@2x 会放大一倍导致元素出界）。
//   为兼顾 Retina 观感，全部内容先在 2x 离屏画布绘制再降采样到 1x
//   （超采样抗锯齿）。
//
// 布局约定（与 make-dmg.sh 的 Finder 布局参数一致，单位均为 1x pt/px）：
//   窗口内容 600×360；app 图标中心 (140, 180)、Applications 别名中心
//   (460, 180)、图标 128pt；两图标之间只画点状引导箭头（无文字，按作者
//   要求）。NSGraphicsContext 原点左下：y = H - 距顶距离。

import AppKit

// 1x 输出尺寸与 2x 超采样因子。
let W: CGFloat = 600
let H: CGFloat = 360
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

// 2. 引导箭头：点状虚线 + 实心箭头头部，灰蓝色，垂直居中（图标行 y=180 距顶）。
let arrowY: CGFloat = H - 180
let startX: CGFloat = 228   // app 图标右缘 204 → 留 24pt
let endX: CGFloat = 372     // Applications 左缘 396 → 留 24pt
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

// 3. 超采样降落到 1x 画布（高质量插值）。
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

