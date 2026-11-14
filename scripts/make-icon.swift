// Renders the Hushy app icon (graphite squircle, glowing lime Wave-H) into an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
//
// The mark is the Wave-H (design/logo-fresh, handbook design/brand): five lime bars — two tall
// stems, a short crossbar, two dots — a symmetric waveform that spells the initial. Geometry in
// a 100-unit box: bars 12 wide on a 20 pitch at x 4/24/44/64/84, heights 12/84/38/84/12, all
// centred on y 50. The menu-bar glyph (MurmurApp.swift, MenuBarGlyph) and the sidebar tile
// (RootView.swift, LogoTile) draw the same five slots so the mark reads the same everywhere.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let lime: UInt32 = 0xC6F432
/// Wave-H bar heights in 100-box units; the dots are as tall as the bars are wide.
let waveH: [CGFloat] = [12, 84, 38, 84, 12]
let barUnits: CGFloat = 12
let pitchUnits: CGFloat = 20
/// From the left edge of the first dot to the right edge of the last: 4 → 96.
let spanUnits: CGFloat = 92

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Body: graphite gradient, a lime atmosphere low in the tile, a bevel that catches light at the
/// top and falls into shadow at the bottom (Big Sur-era depth, no flat fills).
func drawBody(_ context: CGContext, body: CGRect, pixels: CGFloat) {
    let radius = body.width * 0.225
    let shape = rounded(body, radius: radius)
    let space = CGColorSpaceCreateDeviceRGB()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -pixels * 0.012), blur: pixels * 0.03, color: color(0x000000, 0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(color(0x111317).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let graphite = CGGradient(colorsSpace: space, colors: [color(0x23262D).cgColor, color(0x0B0C0F).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(graphite, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    let atmosphere = CGGradient(
        colorsSpace: space,
        colors: [color(lime, 0.20).cgColor, color(lime, 0.05).cgColor, color(lime, 0).cgColor] as CFArray,
        locations: [0, 0.55, 1])!
    let centre = CGPoint(x: body.midX, y: body.midY - body.height * 0.12)
    context.drawRadialGradient(atmosphere, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: body.width * 0.6, options: [])
    context.restoreGState()

    // Bevel: a stroke clipped to the body, lit at the top, shaded at the bottom.
    guard pixels >= 32 else { return }
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.addPath(shape)
    context.setLineWidth(max(1.5, pixels * 0.008))
    context.replacePathWithStrokedPath()
    context.clip()
    let bevel = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF, 0.22).cgColor, color(0xFFFFFF, 0.04).cgColor, color(0x000000, 0.5).cgColor] as CFArray,
        locations: [0, 0.5, 1])!
    context.drawLinearGradient(bevel, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    context.restoreGState()
}

/// The mark at proportional size (≥ 32 px): the 92-unit span takes 72% of the body width, with a
/// tight glow and, once there are pixels to carry it, a wide soft one.
func drawMark(_ context: CGContext, body: CGRect, pixels: CGFloat) {
    let unit = body.width * 0.72 / spanUnits
    let barWidth = barUnits * unit
    var x = body.midX - spanUnits / 2 * unit
    var bars: [CGRect] = []
    for height in waveH {
        let barHeight = height * unit
        bars.append(CGRect(x: x, y: body.midY - barHeight / 2, width: barWidth, height: barHeight))
        x += pitchUnits * unit
    }
    let glows: [(blur: CGFloat, alpha: CGFloat)] = pixels >= 128
        ? [(pixels * 0.09, 0.35), (pixels * 0.035, 0.6)]
        : [(pixels * 0.04, 0.55)]
    for glow in glows {
        context.saveGState()
        context.setShadow(offset: .zero, blur: glow.blur, color: color(lime, glow.alpha).cgColor)
        context.setFillColor(color(lime).cgColor)
        for bar in bars { context.addPath(rounded(bar, radius: barWidth / 2)) }
        context.fillPath()
        context.restoreGState()
    }
    context.setFillColor(color(lime).cgColor)
    for bar in bars { context.addPath(rounded(bar, radius: barWidth / 2)) }
    context.fillPath()
}

/// 16 px pixel plan (no anti-aliased fractions, no glow): stems 2 px at x 4 and 10, crossbar 2 px
/// at x 7, dots 1×2 px at x 2 and 13; heights 10 / 4 / 2, all centred on y 8.
func drawMarkPixelPlan(_ context: CGContext) {
    context.setFillColor(color(lime).cgColor)
    let rects = [
        CGRect(x: 2, y: 7, width: 1, height: 2),
        CGRect(x: 4, y: 3, width: 2, height: 10),
        CGRect(x: 7, y: 6, width: 2, height: 4),
        CGRect(x: 10, y: 3, width: 2, height: 10),
        CGRect(x: 13, y: 7, width: 1, height: 2),
    ]
    for rect in rects { context.addPath(rounded(rect, radius: 0.5)) }
    context.fillPath()
}

func render(size: Int) -> Data {
    let pixels = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with ~225/1024 corner radius (Big Sur+ squircle proportions).
    // At 16 px the body hugs the canvas (1 px inset) so the five slots have whole pixels to sit on.
    let inset = size < 32 ? 1 : pixels * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: pixels - inset * 2, height: pixels - inset * 2)
    drawBody(context, body: body, pixels: pixels)
    if size < 32 { drawMarkPixelPlan(context) } else { drawMark(context, body: body, pixels: pixels) }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(output.path)")
