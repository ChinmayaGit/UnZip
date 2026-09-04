import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 230, yRadius: 230).fill()

NSColor(calibratedRed: 0.91, green: 0.68, blue: 0.32, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 210, y: 250, width: 604, height: 520), xRadius: 64, yRadius: 64).fill()

NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.22, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 320, y: 460, width: 384, height: 64)).fill()
NSBezierPath(rect: NSRect(x: 320, y: 360, width: 260, height: 48)).fill()

image.unlockFocus()

if let tiff = image.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: output))
}
