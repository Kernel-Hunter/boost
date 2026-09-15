import AppKit

// macOS icon geometry: 824pt of content centred in a 1024pt canvas, corner radius 185.
let canvas = 1024.0, inset = 100.0, radius = 185.0

let img = NSImage(size: NSSize(width: canvas, height: canvas))
img.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
let ctx = NSGraphicsContext.current!.cgContext

let content = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let squircle = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)

// Drop shadow so the tile sits on the desktop rather than floating flat.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
              color: NSColor.black.withAlphaComponent(0.34).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()

// Indigo -> electric cyan, on the diagonal.
NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.16, blue: 0.83, alpha: 1),
                    NSColor(srgbRed: 0.15, green: 0.44, blue: 0.98, alpha: 1),
                    NSColor(srgbRed: 0.07, green: 0.78, blue: 1.00, alpha: 1)])?
    .draw(in: content, angle: -62)

// Glow behind the bolt, so the white reads as emitting light.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])?
    .draw(fromCenter: NSPoint(x: canvas * 0.5, y: canvas * 0.52), radius: 0,
          toCenter: NSPoint(x: canvas * 0.5, y: canvas * 0.52), radius: canvas * 0.42,
          options: [])

// Gloss across the top edge.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])?
    .draw(in: NSRect(x: inset, y: canvas * 0.56, width: content.width, height: canvas * 0.34), angle: -90)

// Speed arc — a gauge sweep that says "performance" without adding clutter at 16px.
let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: canvas * 0.5, y: canvas * 0.5), radius: canvas * 0.295,
              startAngle: 208, endAngle: 332, clockwise: true)
arc.lineWidth = 26
arc.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.30).setStroke()
arc.stroke()

// The bolt.
let w = canvas, h = canvas
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: w * 0.588, y: h * 0.815))
bolt.line(to: NSPoint(x: w * 0.337, y: h * 0.468))
bolt.line(to: NSPoint(x: w * 0.483, y: h * 0.468))
bolt.line(to: NSPoint(x: w * 0.424, y: h * 0.175))
bolt.line(to: NSPoint(x: w * 0.675, y: h * 0.522))
bolt.line(to: NSPoint(x: w * 0.529, y: h * 0.522))
bolt.close()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22,
              color: NSColor(srgbRed: 0.04, green: 0.10, blue: 0.45, alpha: 0.55).cgColor)
NSColor.white.setFill()
bolt.fill()
ctx.restoreGState()

ctx.restoreGState()
img.unlockFocus()

let iconset = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
                   (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),
                   (512,"512x512"),(1024,"512x512@2x")] {
    let out = NSImage(size: NSSize(width: px, height: px))
    out.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    out.unlockFocus()
    guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
print("iconset written")
