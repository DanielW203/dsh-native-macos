// make-icon.swift — 把一张「不透明方形图」加工成 macOS 应用图标主图（1024×1024 PNG）。
//
// 做三件事：
//   1. 自动检测图中亮色主体（这里是白底圆角矩形）的外接矩形，裁掉四周的黑底
//   2. 把主体缩放到 Apple 规范的 824×824 内容区，居中放进 1024×1024 透明画布
//   3. 用圆角（半径 185.4，即内容区 22.49%）做遮罩，四角变透明
//
// 用法: swift make-icon.swift <输入.png> <输出.png>

import AppKit
import CoreGraphics
import Foundation

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write("error: \(msg)\n".data(using: .utf8)!)
  exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: make-icon.swift <in.png> <out.png>") }
let srcPath = args[1]
let outPath = args[2]

guard let src = NSImage(contentsOfFile: srcPath),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("cannot load \(srcPath)") }

let w = cg.width
let h = cg.height
let bpr = w * 4
var buf = [UInt8](repeating: 0, count: bpr * h)
buf.withUnsafeMutableBytes { raw in
  let ctx = CGContext(
    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
}

// ── 1. 找亮色主体的外接矩形 ───────────────────────────────────────────────────
let threshold = 100
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
  let row = y * bpr
  for x in 0..<w {
    let i = row + x * 4
    let lum = (Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2])) / 3
    if lum > threshold {
      if x < minX { minX = x }
      if x > maxX { maxX = x }
      if y < minY { minY = y }
      if y > maxY { maxY = y }
    }
  }
}
guard maxX >= 0 else { fail("no bright content found (threshold \(threshold))") }

let content = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
FileHandle.standardError.write(
  "source \(w)x\(h); bright content \(Int(content.width))x\(Int(content.height)) at (\(minX),\(minY))\n"
    .data(using: .utf8)!)

guard let cropped = cg.cropping(to: content) else { fail("cropping failed") }

// ── 2. 按 Apple 规范排版：1024 画布 / 824 内容 / 四周 100 透明留白 ──────────────
let canvas = 1024
let contentSize = 824.0
let inset = (Double(canvas) - contentSize) / 2.0
let target = CGRect(x: inset, y: inset, width: contentSize, height: contentSize)
let radius = contentSize * 0.2249  // ≈185.4

guard let out = CGContext(
  data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("cannot create output context") }

out.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
out.interpolationQuality = .high
out.saveGState()
out.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
out.clip()
out.draw(cropped, in: target)
out.restoreGState()

guard let image = out.makeImage() else { fail("makeImage failed") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fail("png encode failed") }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(canvas)x\(canvas))")
