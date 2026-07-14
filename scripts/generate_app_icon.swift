import AppKit
import CoreGraphics

private let canvas: CGFloat = 1024

private func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

/// A continuous-corner macOS icon silhouette. The canvas keeps a 34 pt optical
/// margin so the exported PNG has transparent corners instead of a white box.
private func squircle(inset: CGFloat = 34) -> CGPath {
    let scale = (canvas - inset * 2) / 956
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: inset + x * scale, y: inset + y * scale)
    }

    let path = CGMutablePath()
    path.move(to: p(234, 0))
    path.addLine(to: p(722, 0))
    path.addCurve(to: p(903, 69), control1: p(804, 0), control2: p(855, 21))
    path.addCurve(to: p(956, 234), control1: p(942, 108), control2: p(956, 158))
    path.addLine(to: p(956, 722))
    path.addCurve(to: p(887, 903), control1: p(956, 804), control2: p(935, 855))
    path.addCurve(to: p(722, 956), control1: p(848, 942), control2: p(798, 956))
    path.addLine(to: p(234, 956))
    path.addCurve(to: p(53, 887), control1: p(152, 956), control2: p(101, 935))
    path.addCurve(to: p(0, 722), control1: p(14, 848), control2: p(0, 798))
    path.addLine(to: p(0, 234))
    path.addCurve(to: p(69, 53), control1: p(0, 152), control2: p(21, 101))
    path.addCurve(to: p(234, 0), control1: p(108, 14), control2: p(158, 0))
    path.closeSubpath()
    return path
}

/// Exact vector geometry for the chosen “04A Balanced Facet” π mark.
/// Coordinates match PiLogo.svg so the app icon and sidebar share one identity.
private func piLogoPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 16, y: 29))
    path.addLine(to: CGPoint(x: 145, y: 18))
    path.addLine(to: CGPoint(x: 141, y: 45))
    path.addLine(to: CGPoint(x: 121, y: 47))
    path.addLine(to: CGPoint(x: 114, y: 108))
    path.addLine(to: CGPoint(x: 88, y: 108))
    path.addLine(to: CGPoint(x: 96, y: 49))
    path.addLine(to: CGPoint(x: 63, y: 52))
    path.addLine(to: CGPoint(x: 56, y: 108))
    path.addLine(to: CGPoint(x: 30, y: 108))
    path.addLine(to: CGPoint(x: 38, y: 54))
    path.addLine(to: CGPoint(x: 12, y: 56))
    path.closeSubpath()

    var transform = CGAffineTransform(a: 4.65, b: 0, c: 0, d: 4.65, tx: 147, ty: 210)
    return path.copy(using: &transform)!
}

private func drawIcon() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(
        data: nil,
        width: Int(canvas),
        height: Int(canvas),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    )!
    context.interpolationQuality = .high

    // Work in top-left coordinates to keep geometry readable.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    let icon = squircle()

    // Layered macOS icon shadow, kept inside the transparent 1024 pt canvas.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: rgba(14, 45, 112, 0.30))
    context.addPath(icon)
    context.setFillColor(rgba(31, 101, 246))
    context.fillPath()
    context.restoreGState()

    // Preview-inspired blue field: pale sky at the top, saturated blue below.
    context.saveGState()
    context.addPath(icon)
    context.clip()
    let baseGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            rgba(158, 202, 255),
            rgba(100, 158, 255),
            rgba(45, 108, 250),
            rgba(24, 77, 223)
        ] as CFArray,
        locations: [0, 0.28, 0.72, 1]
    )!
    context.drawLinearGradient(
        baseGradient,
        start: CGPoint(x: 512, y: 36),
        end: CGPoint(x: 512, y: 992),
        options: []
    )

    // Soft illumination is layered rather than baked into one flat gradient.
    let topGlow = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgba(255, 255, 255, 0.48), rgba(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        topGlow,
        startCenter: CGPoint(x: 250, y: 150), startRadius: 0,
        endCenter: CGPoint(x: 250, y: 150), endRadius: 560,
        options: [.drawsAfterEndLocation]
    )

    let cyanGlow = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgba(83, 229, 255, 0.23), rgba(83, 229, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        cyanGlow,
        startCenter: CGPoint(x: 250, y: 850), startRadius: 0,
        endCenter: CGPoint(x: 250, y: 850), endRadius: 430,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    // Outer optical rim: a bright hairline plus a cooler inner definition.
    context.addPath(icon)
    context.setStrokeColor(rgba(255, 255, 255, 0.72))
    context.setLineWidth(3)
    context.strokePath()
    context.addPath(icon)
    context.setStrokeColor(rgba(16, 70, 184, 0.18))
    context.setLineWidth(1)
    context.strokePath()

    let logo = piLogoPath()

    // Dark refracted edge below the glass makes the mark readable on the pale top.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 15), blur: 26, color: rgba(7, 42, 132, 0.46))
    context.addPath(logo)
    context.setFillColor(rgba(223, 240, 255, 0.42))
    context.fillPath()
    context.restoreGState()

    // Frosted interior. The blue remains visible through the letter while the
    // milky scattering keeps the π mark legible at Dock and Finder sizes.
    context.saveGState()
    context.addPath(logo)
    context.clip()
    let glassFill = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            rgba(250, 253, 255, 0.46),
            rgba(222, 239, 255, 0.31),
            rgba(157, 202, 255, 0.20)
        ] as CFArray,
        locations: [0, 0.48, 1]
    )!
    context.drawLinearGradient(
        glassFill,
        start: CGPoint(x: 512, y: 245),
        end: CGPoint(x: 512, y: 780),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    let glassBloom = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgba(255, 255, 255, 0.34), rgba(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glassBloom,
        startCenter: CGPoint(x: 300, y: 310), startRadius: 0,
        endCenter: CGPoint(x: 300, y: 310), endRadius: 430,
        options: [.drawsAfterEndLocation]
    )

    let lowerCaustic = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgba(224, 247, 255, 0.24), rgba(224, 247, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        lowerCaustic,
        startCenter: CGPoint(x: 490, y: 690), startRadius: 0,
        endCenter: CGPoint(x: 490, y: 690), endRadius: 330,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    // Two edge passes create the bright surface rim and cool refracted underside.
    context.saveGState()
    context.addRect(CGRect(x: 0, y: 220, width: canvas, height: 320))
    context.clip()
    context.addPath(logo)
    context.setStrokeColor(rgba(255, 255, 255, 0.94))
    context.setLineWidth(5)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.addRect(CGRect(x: 0, y: 500, width: canvas, height: 360))
    context.clip()
    context.addPath(logo)
    context.setStrokeColor(rgba(173, 219, 255, 0.68))
    context.setLineWidth(4)
    context.strokePath()
    context.restoreGState()

    // Final full contour keeps the faceted silhouette crisp.
    context.addPath(logo)
    context.setStrokeColor(rgba(255, 255, 255, 0.78))
    context.setLineWidth(2)
    context.strokePath()

    return context.makeImage()!
}

let outputPath = CommandLine.arguments.dropFirst().first ?? "docs/images/pi-liquid-app-icon.png"
let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let representation = NSBitmapImageRep(cgImage: drawIcon())
guard let data = representation.representation(using: .png, properties: [.compressionFactor: 1]) else {
    fatalError("Unable to encode app icon PNG")
}
try data.write(to: outputURL, options: .atomic)
print(outputURL.path)
