import AppKit

let markPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let size = NSSize(width: 1024, height: 1024)

let image = NSImage(size: size)
image.lockFocus()

let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 226, yRadius: 226)
NSColor(white: 0.965, alpha: 1).setFill()
bg.fill()

let border = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4), xRadius: 225, yRadius: 225)
NSColor(white: 0.0, alpha: 0.06).setStroke()
border.lineWidth = 2
border.stroke()

// 橙色标：限宽 840、垂直居中
let mark = NSImage(contentsOfFile: markPath)!
let markW: CGFloat = 840
let markH = markW * (mark.size.height / mark.size.width)
let markRect = NSRect(x: (size.width - markW) / 2, y: (size.height - markH) / 2, width: markW, height: markH)
NSGraphicsContext.current!.imageInterpolation = .high
mark.draw(in: markRect)

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath)")
