import Foundation
import AppKit

// 与界面侧栏一致：Theme.accent 渐变圆角方块 + 白色 brain.head.profile 符号。
// 用 AppKit 渲染 SF Symbol 成 4096 的白色符号层，再交给 make_icon.py 打包。
let size = CGFloat(4096)
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

// LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.65)],
//                startPoint: .topLeading, endPoint: .bottomTrailing)
let start = NSColor(calibratedRed: 0.365, green: 0.400, blue: 0.945, alpha: 1)
let end = NSColor(calibratedRed: 0.365 * 0.65 + 0.35,
                  green: 0.400 * 0.65 + 0.35,
                  blue: 0.945 * 0.65 + 0.35, alpha: 1)
let gradient = NSGradient(starting: start, ending: end)!
gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -45)

let config = NSImage.SymbolConfiguration(pointSize: 2600, weight: .semibold)
guard let base = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil) else {
    FileHandle.standardError.write("symbol not found\n".data(using: .utf8)!)
    exit(1)
}
let img = base.withSymbolConfiguration(config)!

let glyph = NSImage(size: img.size)
glyph.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: img.size).fill()
img.draw(in: NSRect(origin: .zero, size: img.size))
NSColor.white.setFill()
NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
glyph.unlockFocus()

let gs = img.size
let scale = min(size * 0.62 / gs.width, size * 0.62 / gs.height)
let dw = gs.width * scale
let dh = gs.height * scale
let drawRect = NSRect(x: (size - dw) / 2, y: (size - dh) / 2, width: dw, height: dh)
glyph.draw(in: drawRect)

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/ah-icon-master.png"))
print("ok")

