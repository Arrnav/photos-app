#!/usr/bin/env swift
// Draws the app icon: an original six-petal flower in the spirit of a photo library icon
// (ethwood's own design). Usage: swift Scripts/make-app-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Background: soft white with a faint cool shade at the bottom.
let background = CGGradient(colorsSpace: space, colors: [color(1, 1, 1), color(0.93, 0.94, 0.96)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: .zero, options: [])

// Six leaf-shaped petals, gently pointed at the tip, around a small open centre; overlaps blend like tinted glass.
let center = CGPoint(x: size / 2, y: size / 2)
let petals: [(CGFloat, CGFloat, CGFloat)] = [
    (1.00, 0.52, 0.00),   // amber (top)
    (1.00, 0.80, 0.00),   // sunflower
    (0.30, 0.78, 0.14),   // leaf green
    (0.00, 0.58, 0.98),   // sky blue
    (0.47, 0.30, 1.00),   // violet
    (1.00, 0.22, 0.45),   // rose
]
let petalLength: CGFloat = 330
let petalWidth: CGFloat = 230
let inner: CGFloat = 62

for (index, rgb) in petals.enumerated() {
    let angle = CGFloat(index) / CGFloat(petals.count) * 2 * .pi + .pi / 2
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle - .pi / 2)
    // A leaf: widest a little past the middle, narrowing to the centre and to a soft point outside.
    let widest = inner + petalLength * 0.55
    let tip = inner + petalLength
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: inner))
    path.addCurve(to: CGPoint(x: petalWidth / 2, y: widest),
                  control1: CGPoint(x: petalWidth * 0.30, y: inner + 20), control2: CGPoint(x: petalWidth / 2, y: inner + petalLength * 0.28))
    path.addCurve(to: CGPoint(x: 0, y: tip),
                  control1: CGPoint(x: petalWidth / 2, y: inner + petalLength * 0.84), control2: CGPoint(x: petalWidth * 0.14, y: tip - 8))
    path.addCurve(to: CGPoint(x: -petalWidth / 2, y: widest),
                  control1: CGPoint(x: -petalWidth * 0.14, y: tip - 8), control2: CGPoint(x: -petalWidth / 2, y: inner + petalLength * 0.84))
    path.addCurve(to: CGPoint(x: 0, y: inner),
                  control1: CGPoint(x: -petalWidth / 2, y: inner + petalLength * 0.28), control2: CGPoint(x: -petalWidth * 0.30, y: inner + 20))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setBlendMode(.multiply)
    ctx.clip()
    let (r, g, b) = rgb
    let fill = CGGradient(colorsSpace: space, colors: [
        color(min(r + 0.05, 1), min(g + 0.05, 1), min(b + 0.05, 1), 0.95), color(r * 0.9, g * 0.9, b * 0.9, 0.95),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: inner + petalLength), end: CGPoint(x: 0, y: inner), options: [])
    // Glassy highlight towards the outer edge.
    ctx.setBlendMode(.screen)
    let shine = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.25), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(shine, startCenter: CGPoint(x: -petalWidth * 0.12, y: inner + petalLength * 0.78), startRadius: 0,
                           endCenter: CGPoint(x: -petalWidth * 0.12, y: inner + petalLength * 0.78), endRadius: petalWidth * 0.55, options: [])
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
