import AppKit

let wordmarkPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let size = NSSize(width: 1024, height: 1024)

let image = NSImage(size: size)
image.lockFocus()

// 浅色圆角方形底（Apple 风格亮底图标）
let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 226, yRadius: 226)
NSColor(white: 0.965, alpha: 1).setFill()
bg.fill()

let border = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4), xRadius: 225, yRadius: 225)
NSColor(white: 0.0, alpha: 0.06).setStroke()
border.lineWidth = 2
border.stroke()

// 官方 beyerdynamic 字标（保持比例）
let mark = NSImage(contentsOfFile: wordmarkPath)!
let markW: CGFloat = 800
let markH = markW * (mark.size.height / mark.size.width)
let markRect = NSRect(x: (size.width - markW) / 2, y: 540, width: markW, height: markH)
NSGraphicsContext.current!.imageInterpolation = .high
mark.draw(in: markRect)

// 产品名副标（深灰、加字距）
let font = NSFont.systemFont(ofSize: 72, weight: .semibold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(white: 0.32, alpha: 1),
    .kern: 6.0,
]
let text = NSAttributedString(string: "HEADPHONE LAB", attributes: attrs)
let textSize = text.size()
text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: 380))

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath)")
