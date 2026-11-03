// Generates the placeholder app icon (1024x1024 PNG, no alpha).
// Run: swift tools/make-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
let s = CGFloat(size)
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1),
    CGColor(red: 0.35, green: 0.04, blue: 0.07, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
// Green ring = the interval timer.
ctx.setStrokeColor(CGColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1))
ctx.setLineWidth(56)
ctx.strokeEllipse(in: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: 130, dy: 130))
// Big "R".
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let text = NSAttributedString(string: "R", attributes: [
    .font: NSFont.systemFont(ofSize: 520, weight: .black), .foregroundColor: NSColor.white,
])
let ts = text.size()
text.draw(at: NSPoint(x: (s - ts.width) / 2, y: (s - ts.height) / 2 + 8))
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
