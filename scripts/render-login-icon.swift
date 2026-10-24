import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.043, green: 0.043, blue: 0.059, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
NSColor(calibratedRed: 0, green: 0.682, blue: 0.937, alpha: 1).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 64
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 225, y: 512)); arrow.line(to: NSPoint(x: 635, y: 512))
arrow.move(to: NSPoint(x: 475, y: 672)); arrow.line(to: NSPoint(x: 635, y: 512)); arrow.line(to: NSPoint(x: 475, y: 352))
arrow.move(to: NSPoint(x: 790, y: 730)); arrow.line(to: NSPoint(x: 790, y: 294))
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Login-1024.png"))
let contents = """
{"images":[{"filename":"Login-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(to: root.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
