import AppKit

// macOS icon geometry: 824pt of content centred in a 1024pt canvas, corner radius 185.
let canvas = 1024.0, inset = 100.0, radius = 185.0

let img = NSImage(size: NSSize(width: canvas, height: canvas))
img.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
let ctx = NSGraphicsContext.current!.cgContext

let content = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let squircle = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)
let centre = NSPoint(x: canvas * 0.5, y: canvas * 0.5)

// Drop shadow so the tile sits on the desktop rather than floating flat.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
              color: NSColor.black.withAlphaComponent(0.34).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()

// Deep teal-black, the same family as the app's accent.
NSGradient(colors: [NSColor(srgbRed: 0.04, green: 0.09, blue: 0.10, alpha: 1),
                    NSColor(srgbRed: 0.06, green: 0.17, blue: 0.18, alpha: 1)])?
    .draw(in: content, angle: -60)

// Glow behind the gauge, so the ring reads as emitting light.
NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.78, blue: 0.64, alpha: 0.36),
                    NSColor(srgbRed: 0.10, green: 0.78, blue: 0.64, alpha: 0)])?
    .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: canvas * 0.46, options: [])

// Gloss across the top edge.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])?
    .draw(in: NSRect(x: inset, y: canvas * 0.58, width: content.width, height: canvas * 0.32), angle: -90)

// The gauge: a faint track, and a bright arc for memory in use.
let ringRadius = canvas * 0.272, ringWidth = canvas * 0.082
let track = NSBezierPath()
track.appendArc(withCenter: centre, radius: ringRadius, startAngle: 0, endAngle: 360)
track.lineWidth = ringWidth
NSColor.white.withAlphaComponent(0.08).setStroke()
track.stroke()

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
let startColor = (r: 0.10, g: 0.78, b: 0.64), endColor = (r: 0.55, g: 0.98, b: 0.82)
let sweep = 0.74 * 360.0, startAngle = 90.0       // from twelve o'clock, clockwise
let steps = 120
func colour(at t: Double) -> NSColor {
    NSColor(srgbRed: lerp(startColor.r, endColor.r, t), green: lerp(startColor.g, endColor.g, t),
            blue: lerp(startColor.b, endColor.b, t), alpha: 1)
}

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 28, color: NSColor(srgbRed: 0.10, green: 0.78, blue: 0.64, alpha: 0.55).cgColor)
for i in 0..<steps {
    let t0 = Double(i) / Double(steps), t1 = Double(i + 1) / Double(steps)
    let seg = NSBezierPath()
    seg.appendArc(withCenter: centre, radius: ringRadius,
                  startAngle: startAngle - sweep * t0 + 0.4, endAngle: startAngle - sweep * t1 - 0.4,
                  clockwise: true)
    seg.lineWidth = ringWidth
    seg.lineCapStyle = .butt
    colour(at: (t0 + t1) / 2).setStroke()
    seg.stroke()
}
// Round caps at both ends.
for (angle, t) in [(startAngle, 0.0), (startAngle - sweep, 1.0)] {
    let rad = angle * .pi / 180
    let p = NSPoint(x: centre.x + ringRadius * cos(rad), y: centre.y + ringRadius * sin(rad))
    colour(at: t).setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - ringWidth / 2, y: p.y - ringWidth / 2,
                                width: ringWidth, height: ringWidth)).fill()
}
ctx.restoreGState()

// The bolt, sitting inside the ring.
let s = 0.50
func pt(_ x: Double, _ y: Double) -> NSPoint {
    NSPoint(x: canvas * (0.5 + (x - 0.5) * s), y: canvas * (0.5 + (y - 0.5) * s))
}
let bolt = NSBezierPath()
bolt.move(to: pt(0.588, 0.815))
bolt.line(to: pt(0.337, 0.468))
bolt.line(to: pt(0.483, 0.468))
bolt.line(to: pt(0.424, 0.175))
bolt.line(to: pt(0.675, 0.522))
bolt.line(to: pt(0.529, 0.522))
bolt.close()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 18,
              color: NSColor(srgbRed: 0.0, green: 0.12, blue: 0.10, alpha: 0.6).cgColor)
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
