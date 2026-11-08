import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let square = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 220, yRadius: 220)
NSGradient(starting: NSColor(calibratedRed: 0.28, green: 0.43, blue: 0.34, alpha: 1),
           ending: NSColor(calibratedRed: 0.52, green: 0.66, blue: 0.54, alpha: 1))!.draw(in: square, angle: 55)
let leaf = NSBezierPath()
leaf.move(to: NSPoint(x: 265, y: 300))
leaf.curve(to: NSPoint(x: 770, y: 775), controlPoint1: NSPoint(x: 175, y: 690), controlPoint2: NSPoint(x: 575, y: 790))
leaf.curve(to: NSPoint(x: 265, y: 300), controlPoint1: NSPoint(x: 800, y: 395), controlPoint2: NSPoint(x: 540, y: 240))
NSColor(calibratedWhite: 0.98, alpha: 0.94).setFill()
leaf.fill()
let stem = NSBezierPath()
stem.move(to: NSPoint(x: 235, y: 245))
stem.curve(to: NSPoint(x: 645, y: 650), controlPoint1: NSPoint(x: 320, y: 435), controlPoint2: NSPoint(x: 510, y: 535))
stem.lineWidth = 36
stem.lineCapStyle = .round
NSColor(calibratedRed: 0.31, green: 0.47, blue: 0.36, alpha: 1).setStroke()
stem.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
