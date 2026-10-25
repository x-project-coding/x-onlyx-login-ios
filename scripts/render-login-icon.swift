import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let size = 1024
// Explicit RGBX storage avoids AppKit's unsupported three-channel drawing context.
let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
bitmap.setFillColor(CGColor(red: 0.043, green: 0.043, blue: 0.059, alpha: 1))
bitmap.fill(CGRect(x: 0, y: 0, width: size, height: size))
bitmap.setStrokeColor(CGColor(red: 0, green: 0.682, blue: 0.937, alpha: 1))
bitmap.setLineWidth(64)
bitmap.setLineCap(.round)
bitmap.setLineJoin(.round)
bitmap.move(to: CGPoint(x: 225, y: 512)); bitmap.addLine(to: CGPoint(x: 635, y: 512))
bitmap.move(to: CGPoint(x: 475, y: 672)); bitmap.addLine(to: CGPoint(x: 635, y: 512)); bitmap.addLine(to: CGPoint(x: 475, y: 352))
bitmap.move(to: CGPoint(x: 790, y: 730)); bitmap.addLine(to: CGPoint(x: 790, y: 294))
bitmap.strokePath()
let output = CGImageDestinationCreateWithURL(root.appendingPathComponent("Login-1024.png") as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(output, bitmap.makeImage()!, nil)
precondition(CGImageDestinationFinalize(output), "Could not write Login icon")
let contents = """
{"images":[{"filename":"Login-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(to: root.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
