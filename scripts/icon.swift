// Renders Captur's app icon and menu-bar template mark.
//
// The mark is the capsule the app already is: a rounded pill with a level trace
// inside it. That is what the user sees every time they dictate, so the icon and the
// HUD are the same object at two sizes rather than two unrelated drawings.
//
// Legibility over detail: five bars, not twenty. Twenty bars at 16 pt is a grey smear,
// and the menu-bar variant has to survive being a template at exactly that size.
import AppKit
import CoreGraphics
import ImageIO
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// Bar heights as fractions of the capsule's inner height. Asymmetric on purpose — a
/// symmetric trace reads as a decoration, an asymmetric one reads as speech.
///
/// **The small sizes get a different drawing, not the same one shrunk.** Rendered at
/// 16 px, five bars inside a stroked capsule merge into one white blob — checked by
/// rendering it and looking, which is the only way this is knowable. Below 64 px the
/// capsule outline is dropped and three fatter bars carry the mark alone.
func bars(for size: CGFloat) -> [CGFloat] {
    size < 64 ? [0.55, 1.0, 0.42] : [0.34, 0.72, 1.0, 0.55, 0.30]
}

func drawMark(in ctx: CGContext, size: CGFloat, monochrome: Bool) {
    ctx.saveGState()

    // Apple's icon grid: the shape sits inside the canvas rather than filling it.
    let inset = monochrome ? size * 0.06 : size * 0.10
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    if !monochrome {
        // Graphite housing with a restrained highlight, matching the native workspace.
        let path = CGPath(roundedRect: rect,
                          cornerWidth: rect.width * 0.2237,
                          cornerHeight: rect.height * 0.2237,
                          transform: nil)
        ctx.addPath(path)
        ctx.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.23, green: 0.23, blue: 0.26, alpha: 1),
            CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
        ctx.resetClip()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        ctx.setLineWidth(max(1, size * 0.006))
        ctx.strokePath()
    }

    // The capsule.
    let capsuleWidth = rect.width * (monochrome ? 0.92 : 0.62)
    let capsuleHeight = capsuleWidth * (30.0 / 96.0) * 1.55
    let capsule = CGRect(x: rect.midX - capsuleWidth / 2,
                         y: rect.midY - capsuleHeight / 2,
                         width: capsuleWidth,
                         height: capsuleHeight)
    let capsulePath = CGPath(roundedRect: capsule,
                             cornerWidth: capsuleHeight / 2,
                             cornerHeight: capsuleHeight / 2,
                             transform: nil)

    let small = size < 64
    let stroke = max(size * 0.018, monochrome ? 1.0 : 2.0)
    if !small {
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(monochrome ? CGColor(gray: 0, alpha: 1)
                                      : CGColor(gray: 1, alpha: 0.95))
        ctx.addPath(capsulePath)
        ctx.strokePath()
    }

    // The level trace inside it.
    let shape = bars(for: size)
    let innerHeight = small ? rect.height * 0.62 : capsule.height - stroke * 3
    let barWidth = small ? rect.width * 0.13 : capsule.width * 0.072
    let gap = barWidth * (small ? 0.7 : 0.85)
    let totalWidth = CGFloat(shape.count) * barWidth + CGFloat(shape.count - 1) * gap
    var x = capsule.midX - totalWidth / 2
    ctx.setFillColor(monochrome ? CGColor(gray: 0, alpha: 1)
                    : CGColor(red: 0.74, green: 0.64, blue: 0.92, alpha: 1))
    for fraction in shape {
        let height = innerHeight * fraction * (small ? 1.0 : 0.78)
        let bar = CGRect(x: x, y: capsule.midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: bar,
                           cornerWidth: barWidth / 2,
                           cornerHeight: barWidth / 2,
                           transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }

    ctx.restoreGState()
}

func write(size: Int, monochrome: Bool, to path: String) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write(Data("context failed\n".utf8)); exit(1)
    }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawMark(in: ctx, size: CGFloat(size), monochrome: monochrome)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("write failed\n".utf8)); exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path) (\(size)px\(monochrome ? ", template" : ""))")
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(size: size, monochrome: false, to: "\(outDir)/icon_\(size).png")
}
for size in [16, 32, 48] {
    write(size: size, monochrome: true, to: "\(outDir)/menubar_\(size).png")
}
