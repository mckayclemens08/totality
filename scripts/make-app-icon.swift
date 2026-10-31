// Draws the app icon: two rounded triangles, mirrored through the centre, on a soft neumorphic plate.
// Run with `swift scripts/make-app-icon.swift`, which rewrites the PNGs in the asset catalog.
import AppKit
import CoreGraphics

let output = "App/Totality/Assets.xcassets/AppIcon.appiconset"

/// All geometry is on a 1000-point canvas, the size the owner's artwork was drawn at.
let canvas: CGFloat = 1000
let cornerRadius: CGFloat = 117
let upperCentres = [CGPoint(x: 245, y: 267), CGPoint(x: 527, y: 270), CGPoint(x: 245, y: 502)]
let ink = CGColor(srgbRed: 0x19 / 255, green: 0x1C / 255, blue: 0x21 / 255, alpha: 1)
let edgeShadow = CGColor(gray: 0.72, alpha: 1)
let dropShadow = CGColor(gray: 0.55, alpha: 0.42)

func mirrored(_ point: CGPoint) -> CGPoint {
    CGPoint(x: canvas - point.x, y: canvas - point.y)
}

/// A triangle stroked with round joins is exactly the hull of three circles, which is the mark's shape.
func addMark(_ context: CGContext, centres: [CGPoint]) {
    context.setFillColor(ink)
    context.setStrokeColor(ink)
    context.setLineWidth(cornerRadius * 2)
    context.setLineJoin(.round)
    context.addLines(between: centres)
    context.closePath()
    context.drawPath(using: .fillStroke)
}

func draw(in context: CGContext) {
    let plate = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(plate)

    // The soft inner edge, cast by a shape just outside the plate.
    context.saveGState()
    let outside = CGMutablePath()
    outside.addRect(plate.insetBy(dx: -200, dy: -200))
    outside.addRoundedRect(in: plate, cornerWidth: 190, cornerHeight: 190)
    context.setShadow(offset: .zero, blur: 90, color: edgeShadow)
    context.setFillColor(edgeShadow)
    context.addPath(outside)
    context.fillPath(using: .evenOdd)
    context.restoreGState()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 18, height: -28), blur: 60, color: dropShadow)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    addMark(context, centres: upperCentres)
    addMark(context, centres: upperCentres.map(mirrored))
    context.endTransparencyLayer()
    context.restoreGState()
}

func render(pixels: Int, scale drawn: CGFloat, opaque: Bool) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
    )!
    let side = CGFloat(pixels)
    let body = side * drawn
    let inset = (side - body) / 2
    if drawn < 1 {
        // macOS icons sit inside a margin with their own rounded corners.
        context.addPath(CGPath(
            roundedRect: CGRect(x: inset, y: inset, width: body, height: body),
            cornerWidth: body * 0.225, cornerHeight: body * 0.225, transform: nil
        ))
        context.clip()
    }
    context.translateBy(x: inset, y: inset + body)
    context.scaleBy(x: body / canvas, y: -body / canvas)
    draw(in: context)
    return context.makeImage()!
}

func write(_ image: CGImage, to name: String) throws {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: "\(output)/\(name)"))
}

try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
// iOS applies its own corners and refuses transparency, so its icon is a full, opaque square.
try write(render(pixels: 1024, scale: 1, opaque: true), to: "ios-1024.png")
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    try write(render(pixels: pixels, scale: 0.824, opaque: false), to: "mac-\(pixels).png")
}
