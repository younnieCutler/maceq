import AppKit
import CoreGraphics

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size,
                     bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// macOS-style squircle (continuous-corner rounded rect approximation).
let corner: CGFloat = CGFloat(size) * 0.225
let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(squircle)
ctx.clip()

// Soft mint-to-periwinkle gradient — calm, not neon, matches the product's
// Toss/Apple-leaning tone rather than a loud "audio app" look.
let colors = [
    CGColor(red: 0.42, green: 0.85, blue: 0.78, alpha: 1),   // mint
    CGColor(red: 0.53, green: 0.62, blue: 0.98, alpha: 1),   // periwinkle
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                        start: CGPoint(x: 0, y: size),
                        end: CGPoint(x: size, y: 0),
                        options: [])

// A gentle diagonal sheen for a bit of depth without looking glossy/dated.
ctx.saveGState()
ctx.setBlendMode(.plusLighter)
let sheen = [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0),
] as CFArray
let sheenGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen, locations: [0, 1])!
ctx.drawLinearGradient(sheenGradient,
                        start: CGPoint(x: 0, y: size),
                        end: CGPoint(x: size * 6 / 10, y: size * 4 / 10),
                        options: [])
ctx.restoreGState()

// Five rounded EQ bars in a gentle smile curve (short–tall–taller–tall–short)
// rather than a flat meter, which is what reads as "cute" instead of
// "technical readout".
let barCount = 5
let barWidth = CGFloat(size) * 0.09
let gap = CGFloat(size) * 0.055
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
let startX = (CGFloat(size) - totalWidth) / 2
let heightFractions: [CGFloat] = [0.30, 0.52, 0.68, 0.52, 0.30]
let baseY = CGFloat(size) * 0.28

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(size) * 0.012),
              blur: CGFloat(size) * 0.02,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.12))

for i in 0..<barCount {
    let barHeight = CGFloat(size) * heightFractions[i]
    let x = startX + CGFloat(i) * (barWidth + gap)
    let barRect = CGRect(x: x, y: baseY, width: barWidth, height: barHeight)
    let path = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
}

let image = ctx.makeImage()!
let bitmap = NSBitmapImageRep(cgImage: image)
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
