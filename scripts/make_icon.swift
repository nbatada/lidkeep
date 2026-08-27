import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make_icon.swift <output.png>\n", stderr)
    exit(2)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not create icon bitmap.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 205, yRadius: 205)
let tileGradient = NSGradient(
    starting: NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.105, alpha: 1),
    ending: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.22, alpha: 1)
)!
tileGradient.draw(in: tile, angle: 90)

let lid = NSBezierPath(roundedRect: NSRect(x: 205, y: 270, width: 614, height: 500), xRadius: 58, yRadius: 58)
NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
lid.fill()

let screen = NSBezierPath(roundedRect: NSRect(x: 242, y: 307, width: 540, height: 426), xRadius: 32, yRadius: 32)
let screenGradient = NSGradient(
    starting: NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.145, alpha: 1),
    ending: NSColor(calibratedRed: 0.025, green: 0.035, blue: 0.055, alpha: 1)
)!
screenGradient.draw(in: screen, angle: 90)

let awakeGlow = NSBezierPath(ovalIn: NSRect(x: 446, y: 430, width: 132, height: 132))
NSColor(calibratedRed: 0.18, green: 0.86, blue: 0.43, alpha: 0.22).setFill()
awakeGlow.fill()

let awakeDot = NSBezierPath(ovalIn: NSRect(x: 472, y: 456, width: 80, height: 80))
NSColor(calibratedRed: 0.18, green: 0.91, blue: 0.45, alpha: 1).setFill()
awakeDot.fill()

let base = NSBezierPath()
base.move(to: NSPoint(x: 165, y: 265))
base.line(to: NSPoint(x: 859, y: 265))
base.curve(
    to: NSPoint(x: 792, y: 216),
    controlPoint1: NSPoint(x: 852, y: 236),
    controlPoint2: NSPoint(x: 826, y: 216)
)
base.line(to: NSPoint(x: 232, y: 216))
base.curve(
    to: NSPoint(x: 165, y: 265),
    controlPoint1: NSPoint(x: 198, y: 216),
    controlPoint2: NSPoint(x: 172, y: 236)
)
base.close()
NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
base.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode icon PNG.\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
