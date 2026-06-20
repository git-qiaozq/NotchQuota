// make_icon.swift — 程序化绘制 NotchQuota 应用图标(1024x1024)
// 暗色 squircle + 顶部刘海 + 三条绿色用量条
import AppKit
import CoreGraphics
import CoreText
import Foundation

let S: CGFloat = 1024
let size = NSSize(width: S, height: S)

let img = NSImage(size: size)
img.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// ── 1. 背景 squircle(深色纵向渐变) ──
let bgRect = CGRect(x: 0, y: 0, width: S, height: S)
let bgPath = CGPath(roundedRect: bgRect.insetBy(dx: 18, dy: 18),
                    cornerWidth: 230, cornerHeight: 230, transform: nil)
ctx.addPath(bgPath); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [
                        CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
                        CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1),
                      ] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S),
                       end: CGPoint(x: 0, y: 0), options: [])

// ── 2. 顶部刘海(纯黑药丸) ──
let notchW: CGFloat = 460, notchH: CGFloat = 96
let notchRect = CGRect(x: (S - notchW) / 2, y: S - 150 - notchH,
                       width: notchW, height: notchH)
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.addPath(CGPath(roundedRect: notchRect, cornerWidth: notchH / 2,
                   cornerHeight: notchH / 2, transform: nil))
ctx.fillPath()

// ── 3. 三条用量条(暗轨道 + 绿色填充,不同水位) ──
let barW: CGFloat = 640, barH: CGFloat = 52
let fills: [CGFloat] = [0.30, 0.64, 0.16]
let groupTop: CGFloat = notchRect.minY - 110
let barGap: CGFloat = 92
for (i, f) in fills.enumerated() {
    let y = groupTop - CGFloat(i) * barGap - barH
    let r = CGRect(x: (S - barW) / 2, y: y, width: barW, height: barH)
    // 轨道
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barH / 2,
                       cornerHeight: barH / 2, transform: nil))
    ctx.fillPath()
    // 填充
    let fw = barW * f
    let fr = CGRect(x: r.minX, y: r.minY, width: fw, height: barH)
    let fgrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [
                             CGColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1),
                             CGColor(red: 0.10, green: 0.66, blue: 0.45, alpha: 1),
                           ] as CFArray,
                           locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: fr, cornerWidth: barH / 2,
                       cornerHeight: barH / 2, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(fgrad, start: CGPoint(x: fr.minX, y: 0),
                           end: CGPoint(x: fr.maxX, y: 0), options: [])
    // 高光
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    let hl = CGRect(x: fr.minX, y: fr.maxY - 14, width: fw, height: 8)
    ctx.addPath(CGPath(roundedRect: hl, cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

// ── 4. 外边描边(极淡,提升边缘清晰度) ──
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
ctx.setLineWidth(2)
ctx.addPath(CGPath(roundedRect: bgRect.insetBy(dx: 19, dy: 19),
                   cornerWidth: 229, cornerHeight: 229, transform: nil))
ctx.strokePath()

img.unlockFocus()

// ── 导出 PNG ──
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                                          : "AppIconSource.png"
try! png.write(to: URL(fileURLWithPath: out))
print("✅ 图标已生成: \(out) (\(Int(S))x\(Int(S)))")
