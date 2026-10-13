// Renders the Landfall app icon: an arrow coming in to land on a shoreline.
//
//   swift scripts/make-icon.swift flat <out.png> [size]   one flattened image (previews, README)
//   swift scripts/make-icon.swift icon <Landfall.icon>     Icon Composer document for macOS 26+:
//        full-bleed layers (sky, shore, arrow); the system adds the shape, shadow and Liquid Glass,
//        and actool derives the flat icns for older macOS.
import AppKit
import CoreGraphics

let cs = CGColorSpace(name: CGColorSpace.displayP3)!

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                         CGFloat(hex & 0xff) / 255, a])!
}

func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { c($0.0) } as CFArray, locations: stops.map(\.1))!
}

/// The design lives on a 1024 grid where the icon body spans 100…924.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func canvas(_ size: CGFloat) -> CGContext {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)  // y grows downward, like the design grid
    return ctx
}

/// Full-bleed: map the body (100…924) onto the whole canvas.
func fullBleed(_ ctx: CGContext, _ size: CGFloat) {
    let k = size / body.width
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -body.minX, y: -body.minY)
}

func save(_ ctx: CGContext, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Layers

func drawSky(_ ctx: CGContext) {
    ctx.drawLinearGradient(gradient([(0x0B2545, 0), (0x13497A, 0.45), (0x1F7FB8, 0.78), (0x45B4D9, 1)]),
                           start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY - 200),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    for (x, y, r) in [(250, 230, 5), (330, 175, 3.5), (720, 210, 4.5), (790, 300, 3), (640, 150, 3), (205, 345, 3)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.setFillColor(c(0xFFFFFF, 0.55))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
}

func shoreline() -> CGMutablePath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: body.minX - 40, y: 762))
    p.addCurve(to: CGPoint(x: body.maxX + 40, y: 734), control1: CGPoint(x: 340, y: 690), control2: CGPoint(x: 680, y: 690))
    return p
}

func drawShore(_ ctx: CGContext) {
    func wave(_ y: CGFloat, amp: CGFloat, alpha: CGFloat) {
        let p = CGMutablePath()
        var x = body.minX - 60
        p.move(to: CGPoint(x: x, y: y))
        while x < body.maxX + 60 {
            p.addQuadCurve(to: CGPoint(x: x + 70, y: y), control: CGPoint(x: x + 35, y: y - amp))
            p.addQuadCurve(to: CGPoint(x: x + 140, y: y), control: CGPoint(x: x + 105, y: y + amp))
            x += 140
        }
        ctx.addPath(p)
        ctx.setStrokeColor(c(0xFFFFFF, alpha))
        ctx.setLineWidth(10)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
    wave(640, amp: 14, alpha: 0.22)
    wave(690, amp: 12, alpha: 0.35)

    let land = shoreline()
    land.addLine(to: CGPoint(x: body.maxX + 40, y: body.maxY + 40))
    land.addLine(to: CGPoint(x: body.minX - 40, y: body.maxY + 40))
    land.closeSubpath()
    ctx.saveGState()
    ctx.addPath(land)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xF6DDA8, 0), (0xEABF77, 0.55), (0xD49A4E, 1)]),
                           start: CGPoint(x: 0, y: 690), end: CGPoint(x: 0, y: body.maxY), options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.addPath(shoreline())
    ctx.setStrokeColor(c(0xFFF4DC, 0.9))
    ctx.setLineWidth(9)
    ctx.strokePath()
    // Where the arrow touches down.
    ctx.setFillColor(c(0xFFF4DC, 0.35))
    ctx.fillEllipse(in: CGRect(x: 392, y: 690, width: 240, height: 44))
}

func arrowPath() -> (CGPath, CGPath) {
    let cx: CGFloat = 512, shaftW: CGFloat = 112, headW: CGFloat = 300, top: CGFloat = 230, neck: CGFloat = 500, tip: CGFloat = 708
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - shaftW / 2, y: top))
    p.addLine(to: CGPoint(x: cx + shaftW / 2, y: top))
    p.addLine(to: CGPoint(x: cx + shaftW / 2, y: neck))
    p.addLine(to: CGPoint(x: cx + headW / 2, y: neck))
    p.addLine(to: CGPoint(x: cx, y: tip))
    p.addLine(to: CGPoint(x: cx - headW / 2, y: neck))
    p.addLine(to: CGPoint(x: cx - shaftW / 2, y: neck))
    p.closeSubpath()
    return (p, p.copy(strokingWithWidth: 34, lineCap: .round, lineJoin: .round, miterLimit: 10))
}

func drawArrow(_ ctx: CGContext, shaded: Bool) {
    let (arrow, rounded) = arrowPath()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(c(0xFFFFFF))
    ctx.addPath(arrow)
    ctx.fillPath()
    ctx.addPath(rounded)
    ctx.fillPath()
    if shaded {
        ctx.setBlendMode(.sourceAtop)
        ctx.setFillColor(c(0xD3E4F2, 0.8))
        ctx.fill(CGRect(x: 512, y: 150, width: 260, height: 620))
    }
    ctx.endTransparencyLayer()
}

// MARK: - Outputs

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "flat"

if mode == "icon" {
    let doc = URL(fileURLWithPath: args.count > 2 ? args[2] : "Resources/Landfall.icon")
    let assets = doc.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: doc)
    try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    for (name, draw) in [("sky", { drawSky($0) }), ("shore", { drawShore($0) }), ("arrow", { drawArrow($0, shaded: false) })]
        as [(String, (CGContext) -> Void)] {
        let ctx = canvas(1024)
        fullBleed(ctx, 1024)
        draw(ctx)
        save(ctx, assets.appendingPathComponent("\(name).png"))
    }
    // Front to back. The arrow is the glass layer; the scene stays opaque.
    let json = """
    {
      "fill" : { "solid" : "display-p3:0.04314,0.14510,0.27059,1.00000" },
      "groups" : [
        {
          "layers" : [ { "glass" : true, "image-name" : "arrow.png", "name" : "arrow" } ],
          "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
          "translucency" : { "enabled" : true, "value" : 0.25 }
        },
        {
          "layers" : [ { "glass" : false, "image-name" : "shore.png", "name" : "shore" } ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.3 }
        },
        {
          "layers" : [ { "glass" : false, "image-name" : "sky.png", "name" : "sky" } ]
        }
      ],
      "supported-platforms" : { "squares" : "shared" }
    }
    """
    try! json.write(to: doc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote \(doc.path)")
} else {
    let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "icon-1024.png")
    let S = CGFloat(args.count > 3 ? Double(args[3])! : 1024)
    let ctx = canvas(S)
    ctx.scaleBy(x: S / 1024, y: S / 1024)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: c(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(c(0x0B2545))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    drawSky(ctx)
    drawShore(ctx)
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: c(0x061A33, 0.55))
    drawArrow(ctx, shaded: true)
    ctx.restoreGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(c(0xFFFFFF, 0.12))
    ctx.setLineWidth(2)
    ctx.strokePath()
    save(ctx, out)
    print("wrote \(out.path) (\(Int(S))px)")
}
