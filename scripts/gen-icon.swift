#!/usr/bin/env swift
// gen-icon.swift: draws transcribe-thing's app icon with CoreGraphics.
//
// Usage: swift scripts/gen-icon.swift [Resources]
// Writes into the given folder (default: Resources next to this script's parent):
//   AppIcon.png    1024x1024 master (full macOS grid: 824 pt squircle body, shadow, transparent margin)
//   AppIcon.icns   all ten sizes via iconutil
//   AppIcon.icon/  Icon Composer package (background gradient + glyph layer) for macOS 26 Liquid Glass;
//                  scripts/build-app.sh compiles it with actool when available.
//
// The artwork: a black-to-graphite squircle with a quiet top light;
// in the middle, a white capsule (transcribe-thing's pill, inverted) holding five rounded waveform bars.
import AppKit
import CoreGraphics
import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let defaultOut = scriptURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
let outDir = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : defaultOut

let canvas: CGFloat = 1024
let body: CGFloat = 824
let margin: CGFloat = (canvas - body) / 2
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
/// CGContext shadows live in device space and ignore the CTM, so every shadow is scaled by hand.
nonisolated(unsafe) var deviceScale: CGFloat = 1

func setShadow(_ ctx: CGContext, dy: CGFloat, blur: CGFloat, color: CGColor) {
    ctx.setShadow(offset: CGSize(width: 0, height: dy * deviceScale), blur: blur * deviceScale, color: color)
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

/// Superellipse close to Apple's continuous-corner icon outline.
func squircle(in r: CGRect, n: CGFloat = 5.2, steps: Int = 1440) -> CGPath {
    let path = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = r.midY + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func capsule(_ r: CGRect) -> CGPath {
    let radius = min(r.width, r.height) / 2
    return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Palette: black and white, like the app (Theme.swift).
let barTop = rgb(0x2A2A2A)
let barMid = rgb(0x151515)
let barDeep = rgb(0x000000)
let ink = rgb(0x0A0A0A)

/// The glyph, centred on `center`: white capsule + five bars. `forGlass` omits the capsule's own shadow and
/// glow (the system adds depth to Liquid Glass layers).
func drawGlyph(_ ctx: CGContext, center: CGPoint, scale s: CGFloat, forGlass: Bool) {
    let pillW = 568 * s, pillH = 244 * s
    let pill = CGRect(x: center.x - pillW / 2, y: center.y - pillH / 2, width: pillW, height: pillH)

    if !forGlass {
        // Lit halo behind the capsule: the "quiet glow".
        ctx.saveGState()
        let halo = gradient([(rgb(0xFFFFFF, 0.22), 0), (rgb(0xFFFFFF, 0.08), 0.45), (rgb(0xFFFFFF, 0.0), 1)])
        ctx.saveGState()
        // Stretch the halo horizontally so it follows the capsule.
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1.55, y: 1)
        ctx.drawRadialGradient(halo, startCenter: .zero, startRadius: 0, endCenter: .zero,
                               endRadius: pillH * 1.25, options: [])
        ctx.restoreGState()
        ctx.restoreGState()

        // Two-layer shadow: a tight contact shadow and a wide soft one.
        ctx.saveGState()
        setShadow(ctx, dy: -34 * s, blur: 70 * s, color: rgb(0x000000, 0.55))
        ctx.addPath(capsule(pill))
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        setShadow(ctx, dy: -6 * s, blur: 12 * s, color: rgb(0x000000, 0.35))
        ctx.addPath(capsule(pill))
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Capsule body: paper white with a faint gray fall-off towards the bottom.
    ctx.saveGState()
    ctx.addPath(capsule(pill))
    ctx.clip()
    let paper = gradient([(rgb(0xFFFFFF), 0), (rgb(0xF5F5F5), 0.55), (rgb(0xE4E4E4), 1)])
    ctx.drawLinearGradient(paper, start: CGPoint(x: pill.midX, y: pill.maxY), end: CGPoint(x: pill.midX, y: pill.minY), options: [])
    if !forGlass {
        // Soft specular band along the top edge.
        let sheen = gradient([(rgb(0xFFFFFF, 0.9), 0), (rgb(0xFFFFFF, 0), 1)])
        ctx.drawLinearGradient(sheen, start: CGPoint(x: pill.midX, y: pill.maxY),
                               end: CGPoint(x: pill.midX, y: pill.maxY - pillH * 0.35), options: [])
    }
    ctx.restoreGState()

    // Inner hairline so the capsule edge reads crisply at small sizes.
    if !forGlass {
        ctx.saveGState()
        ctx.addPath(capsule(pill.insetBy(dx: 1.5 * s, dy: 1.5 * s)))
        ctx.setStrokeColor(rgb(0x000000, 0.10))
        ctx.setLineWidth(3 * s)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Five bars, centre-weighted like the live waveform.
    let heights: [CGFloat] = [66, 118, 164, 118, 66]
    let barW: CGFloat = 38 * s, gap: CGFloat = 32 * s
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = center.x - total / 2
    let barFill = gradient([(barTop, 0), (barMid, 0.45), (barDeep, 1)])
    for h in heights {
        let r = CGRect(x: x, y: center.y - h * s / 2, width: barW, height: h * s)
        ctx.saveGState()
        ctx.addPath(capsule(r))
        ctx.clip()
        ctx.drawLinearGradient(barFill, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
        ctx.restoreGState()
        x += barW + gap
    }
}

func drawBackground(_ ctx: CGContext, in rect: CGRect) {
    // Black (bottom right) rising to graphite (top left).
    let base = gradient([(rgb(0x3A3A3A), 0), (rgb(0x222222), 0.34), (rgb(0x0E0E0E), 0.74), (rgb(0x000000), 1)])
    ctx.drawLinearGradient(base, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Top light.
    let top = gradient([(rgb(0xFFFFFF, 0.26), 0), (rgb(0xFFFFFF, 0), 1)])
    let topCenter = CGPoint(x: rect.midX - rect.width * 0.08, y: rect.maxY + rect.height * 0.06)
    ctx.drawRadialGradient(top, startCenter: topCenter, startRadius: 0, endCenter: topCenter,
                           endRadius: rect.width * 0.78, options: [])
}

func makeContext(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func drawIcon(size px: Int) -> CGImage {
    let ctx = makeContext(px)
    let k = CGFloat(px) / canvas
    deviceScale = k
    ctx.scaleBy(x: k, y: k)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let rect = CGRect(x: margin, y: margin, width: body, height: body)
    let shape = squircle(in: rect)

    // Tile drop shadow per the macOS icon grid.
    ctx.saveGState()
    setShadow(ctx, dy: -10, blur: 24, color: rgb(0x000000, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(ink)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawBackground(ctx, in: rect)
    drawGlyph(ctx, center: CGPoint(x: canvas / 2, y: canvas / 2 + 4), scale: 1, forGlass: false)
    ctx.restoreGState()

    // Rim light: brighter along the top edge, fading out towards the bottom.
    ctx.saveGState()
    ctx.addPath(squircle(in: rect.insetBy(dx: 2, dy: 2)))
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = gradient([(rgb(0xFFFFFF, 0.34), 0), (rgb(0xFFFFFF, 0.06), 0.5), (rgb(0xFFFFFF, 0.02), 1)])
    ctx.drawLinearGradient(rim, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

func drawGlassForeground() -> CGImage {
    let ctx = makeContext(1024)
    deviceScale = 1
    drawGlyph(ctx, center: CGPoint(x: 512, y: 512), scale: 1.12, forGlass: true)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let fm = FileManager.default
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
try writePNG(drawIcon(size: 1024), to: outDir.appendingPathComponent("AppIcon.png"))

// .icns through a temporary iconset.
let work = fm.temporaryDirectory.appendingPathComponent("transcribe-thing-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(drawIcon(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(drawIcon(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: work)
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

// Icon Composer package: the system renders the squircle, glass and shadow from these layers.
let package = outDir.appendingPathComponent("AppIcon.icon")
try? fm.removeItem(at: package)
try fm.createDirectory(at: package.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try writePNG(drawGlassForeground(), to: package.appendingPathComponent("Assets/glyph.png"))
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "extended-srgb:0.22745,0.22745,0.22745,1.00000",
      "extended-srgb:0.00000,0.00000,0.00000,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "glyph.png",
          "name" : "glyph"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : true,
        "value" : 0.25
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
"""
try iconJSON.write(to: package.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Wrote \(outDir.path)/AppIcon.png, AppIcon.icns, AppIcon.icon")
