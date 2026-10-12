// Renders the Landfall app icon: an arrow coming in to land on a shoreline.
// usage: swift scripts/make-icon.swift <out.png> [size]
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "icon-1024.png")
let S = CGFloat(args.count > 2 ? Double(args[2])! : 1024)
let u = S / 1024  // design units are on a 1024 grid

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)  // y grows downward, like the design grid

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                         CGFloat(hex & 0xff) / 255, a])!
}

func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { c($0.0) } as CFArray, locations: stops.map(\.1))!
}

// macOS icon grid: 824pt body inset 100pt, continuous-corner squircle.
let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
let squircle = CGPath(roundedRect: body, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10 * u), blur: 28 * u, color: c(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(c(0x0B2545))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Sky/sea: deep navy into ocean blue.
ctx.drawLinearGradient(gradient([(0x0B2545, 0), (0x13497A, 0.45), (0x1F7FB8, 0.78), (0x45B4D9, 1)]),
                       start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY - 200 * u), options: [.drawsAfterEndLocation])

// A few stars, quietly.
for (x, y, r) in [(250, 230, 5), (330, 175, 3.5), (720, 210, 4.5), (790, 300, 3), (640, 150, 3), (205, 345, 3)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.setFillColor(c(0xFFFFFF, 0.55))
    ctx.fillEllipse(in: CGRect(x: (x - r) * u, y: (y - r) * u, width: 2 * r * u, height: 2 * r * u))
}

// Waves: two soft bands above the shore.
func wave(_ y: CGFloat, amp: CGFloat, color: CGColor, width: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: body.minX - 20 * u, y: y * u))
    var x = body.minX - 20 * u
    while x < body.maxX + 20 * u {
        p.addQuadCurve(to: CGPoint(x: x + 70 * u, y: y * u), control: CGPoint(x: x + 35 * u, y: (y - amp) * u))
        p.addQuadCurve(to: CGPoint(x: x + 140 * u, y: y * u), control: CGPoint(x: x + 105 * u, y: (y + amp) * u))
        x += 140 * u
    }
    ctx.addPath(p)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width * u)
    ctx.setLineCap(.round)
    ctx.strokePath()
}
wave(640, amp: 14, color: c(0xFFFFFF, 0.22), width: 10)
wave(690, amp: 12, color: c(0xFFFFFF, 0.35), width: 10)

// The shore: a sand-colored landmass rising from the bottom.
let land = CGMutablePath()
land.move(to: CGPoint(x: body.minX, y: 760 * u))
land.addCurve(to: CGPoint(x: body.maxX, y: 735 * u),
              control1: CGPoint(x: 340 * u, y: 690 * u), control2: CGPoint(x: 680 * u, y: 690 * u))
land.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
land.addLine(to: CGPoint(x: body.minX, y: body.maxY))
land.closeSubpath()
ctx.saveGState()
ctx.addPath(land)
ctx.clip()
ctx.drawLinearGradient(gradient([(0xF6DDA8, 0), (0xEABF77, 0.55), (0xD49A4E, 1)]),
                       start: CGPoint(x: 0, y: 690 * u), end: CGPoint(x: 0, y: body.maxY), options: [])
ctx.restoreGState()
// Wet edge of the sand.
let edge = CGMutablePath()
edge.move(to: CGPoint(x: body.minX, y: 760 * u))
edge.addCurve(to: CGPoint(x: body.maxX, y: 735 * u),
              control1: CGPoint(x: 340 * u, y: 690 * u), control2: CGPoint(x: 680 * u, y: 690 * u))
ctx.addPath(edge)
ctx.setStrokeColor(c(0xFFF4DC, 0.9))
ctx.setLineWidth(9 * u)
ctx.strokePath()

// The landing: a bold arrow touching down, with a glow where it meets the sand.
let cx: CGFloat = 512
ctx.setFillColor(c(0xFFF4DC, 0.35))
ctx.fillEllipse(in: CGRect(x: (cx - 120) * u, y: 690 * u, width: 240 * u, height: 44 * u))

let arrow = CGMutablePath()
let shaftW: CGFloat = 112, headW: CGFloat = 300, top: CGFloat = 230, neck: CGFloat = 500, tip: CGFloat = 708
arrow.move(to: CGPoint(x: (cx - shaftW / 2) * u, y: top * u))
arrow.addLine(to: CGPoint(x: (cx + shaftW / 2) * u, y: top * u))
arrow.addLine(to: CGPoint(x: (cx + shaftW / 2) * u, y: neck * u))
arrow.addLine(to: CGPoint(x: (cx + headW / 2) * u, y: neck * u))
arrow.addLine(to: CGPoint(x: cx * u, y: tip * u))
arrow.addLine(to: CGPoint(x: (cx - headW / 2) * u, y: neck * u))
arrow.addLine(to: CGPoint(x: (cx - shaftW / 2) * u, y: neck * u))
arrow.closeSubpath()
let rounded = arrow.copy(strokingWithWidth: 34 * u, lineCap: .round, lineJoin: .round, miterLimit: 10)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14 * u), blur: 26 * u, color: c(0x061A33, 0.55))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(c(0xFFFFFF))
ctx.addPath(arrow)
ctx.fillPath()
ctx.addPath(rounded)
ctx.fillPath()
// Subtle shading on the arrow's right half.
ctx.setBlendMode(.sourceAtop)
ctx.setFillColor(c(0xD3E4F2, 0.8))
ctx.fill(CGRect(x: cx * u, y: 150 * u, width: 260 * u, height: 620 * u))
ctx.endTransparencyLayer()
ctx.restoreGState()

ctx.restoreGState()

// Hairline rim.
ctx.addPath(squircle)
ctx.setStrokeColor(c(0xFFFFFF, 0.12))
ctx.setLineWidth(2 * u)
ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path) (\(Int(S))px)")
