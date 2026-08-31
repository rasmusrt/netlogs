// Netlogs app icon. Run via make-icon.sh.
//
// The shape is the app's own subject: a flat idle baseline, one sharp spike
// where load arrives, and a settle to a *higher* plateau than before. That is
// bufferbloat — the thing plan §7 calls the most valuable measurement here —
// drawn literally. It also survives downscaling, which the fussier ideas did
// not: at 16 pt it still reads as a line that steps up.
import AppKit

let px: CGFloat = 1024

// macOS icon grid: the shape occupies 824×824 inside a 1024×1024 canvas, so the
// surrounding margin leaves room for the system's shadow. The previous
// placeholder used an 856×856 rect with circular corners, which sat slightly
// large and read subtly wrong beside real app icons.
let side: CGFloat = 824
let origin = (px - side) / 2
let square = CGRect(x: origin, y: origin, width: side, height: side)

/// Apple's rounded-rectangle corners are continuous, not circular arcs. A
/// superellipse with n = 5 is visually indistinguishable at icon sizes and is a
/// few lines instead of a table of Bézier control points.
func squircle(in rect: CGRect, n: Double = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for step in 0...steps {
        let t = 2 * Double.pi * Double(step) / Double(steps)
        let c = cos(t), s = sin(t)
        let x = cx + a * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = cy + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

let image = NSImage(size: NSSize(width: px, height: px))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
ctx.setAllowsAntialiasing(true)

let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Ground.
ctx.saveGState()
ctx.addPath(squircle(in: square))
ctx.clip()
let ground = CGGradient(
    colorsSpace: space,
    colors: [rgb(0.11, 0.16, 0.29), rgb(0.03, 0.05, 0.11)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    ground,
    start: CGPoint(x: square.midX, y: square.maxY),
    end: CGPoint(x: square.midX, y: square.minY),
    options: []
)

// The trace, in fractions of the square: idle → spike → higher plateau.
//
// Runs past both edges so the squircle clips it. A trace that stops short
// leaves two round caps floating in the field and reads as a drawing of a line;
// one that bleeds reads as a continuous signal passing through.
let points: [(CGFloat, CGFloat)] = [
    (-0.08, 0.34), (0.14, 0.34), (0.24, 0.37), (0.33, 0.31), (0.40, 0.35),
    (0.50, 0.82),
    (0.59, 0.54), (0.70, 0.59), (0.80, 0.55), (1.08, 0.57),
]
func point(_ p: (CGFloat, CGFloat)) -> CGPoint {
    CGPoint(x: square.minX + square.width * p.0, y: square.minY + square.height * p.1)
}

// Area under the trace, so the icon has mass at small sizes rather than one
// thin stroke floating in a dark field.
let area = CGMutablePath()
area.move(to: CGPoint(x: point(points[0]).x, y: square.minY - 1))
for p in points { area.addLine(to: point(p)) }
area.addLine(to: CGPoint(x: point(points[points.count - 1]).x, y: square.minY - 1))
area.closeSubpath()
ctx.saveGState()
ctx.addPath(area)
ctx.clip()
let wash = CGGradient(
    colorsSpace: space,
    colors: [rgb(0.35, 0.80, 1.0, 0.40), rgb(0.35, 0.80, 1.0, 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    wash,
    start: CGPoint(x: square.midX, y: square.minY + square.height * 0.82),
    end: CGPoint(x: square.midX, y: square.minY + square.height * 0.18),
    options: []
)
ctx.restoreGState()

// The trace itself.
let trace = CGMutablePath()
for (index, p) in points.enumerated() {
    index == 0 ? trace.move(to: point(p)) : trace.addLine(to: point(p))
}
ctx.setLineWidth(64)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(rgb(0.42, 0.84, 1.0))
ctx.addPath(trace)
ctx.strokePath()

ctx.restoreGState()

// Hairline rim, the way system icons catch light along the top edge.
ctx.addPath(squircle(in: square.insetBy(dx: 1.5, dy: 1.5)))
ctx.setLineWidth(3)
ctx.setStrokeColor(rgb(1, 1, 1, 0.10))
ctx.strokePath()

image.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
