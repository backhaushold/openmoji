// Alpha-snap measurement (openmoji-ufo). Would snapping alpha 250...254 to 255 on the ImageIO
// thumbnail, before PNG encode, shrink the sticker PNG, and would anything visible change?
// Result and decision: docs/spikes/m1-findings.md, "Alpha snap". Not part of the app or CI.
//
//   swiftc -O spikes/m1/alpha-snap.swift -o /tmp/alpha-snap
//   /tmp/alpha-snap dir <raw-png-dir>   real raw model PNGs (spikes/m1/out/raw/<template>/<quality>)
//   /tmp/alpha-snap synthetic           generated fixtures; needs no files
//   /tmp/alpha-snap sheets [<dir>]      alpha structure of the real stickers from the M1 contact
//                                       sheets (<dir>/<quality>-light.png and -dark.png), next to
//                                       the same statistic on each synthetic alpha model
//
// `dir` and `synthetic` print one CSV row per (input, ladder edge): PNG bytes with the current
// pipeline (tech spec 7.1) and with the snap applied to the thumbnail, how many pixels the snap
// touched, whether pixels below alpha 250 stayed byte-identical, and how far the touched pixels
// move when composited on white or black. The snap here is the candidate; it is not in
// StickerProcessor.

// A throwaway analysis script: function length and complexity rules don't fit it, and
// splitting it up would only obscure the one-pass flow (same exemption as spike.swift).
// swiftlint:disable cyclomatic_complexity function_body_length

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let edgeLadder = [618, 560, 512, 448, 384, 300]
let byteLimit = 500_000
let snapThreshold = 250

// MARK: - Pipeline under test

func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> CGImage? {
    let options =
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
}

func encodePNG(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

/// Alpha 250...254 becomes 255, and the colour is un-premultiplied from the old alpha so the
/// pixel keeps its colour. Pixels below 250 (anti-aliased edges) and at 0 or 255 are untouched.
func snapNearOpaqueAlpha(_ image: CGImage) -> CGImage {
    guard
        let space = image.colorSpace, space.model == .rgb,
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let pixels = context.data
    else { return image }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytesPerRow = context.bytesPerRow
    let base = pixels.assumingMemoryBound(to: UInt8.self)
    for y in 0 ..< image.height {
        var pixel = base + y * bytesPerRow
        for _ in 0 ..< image.width {
            let alpha = Int(pixel[3])
            if alpha >= snapThreshold, alpha < 255 {
                for channel in 0 ..< 3 {
                    pixel[channel] = UInt8(min(255, (Int(pixel[channel]) * 255 + alpha / 2) / alpha))
                }
                pixel[3] = 255
            }
            pixel += 4
        }
    }
    return context.makeImage() ?? image
}

// MARK: - Comparison

struct Pixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]  // premultiplied sRGB RGBA, tightly packed, top row first
}

func pixels(of image: CGImage) -> Pixels {
    let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    buffer.withUnsafeMutableBytes { bytes in
        let context = CGContext(
            data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return Pixels(width: image.width, height: image.height, rgba: buffer)
}

struct Difference {
    var visible = 0  // pixels with alpha above 0
    var snapped = 0  // pixels whose alpha was 250...254
    var lowAlphaChanged = 0  // pixels below alpha 250 that differ at all (must be 0)
    var maxLevels = 0  // largest composite change over white or black, in 8-bit levels
    var over2Levels = 0  // pixels whose composite changes by more than 2 levels
}

func compare(_ before: Pixels, _ after: Pixels) -> Difference {
    var result = Difference()
    for index in 0 ..< before.width * before.height {
        let offset = index * 4
        let alpha = Int(before.rgba[offset + 3])
        if alpha > 0 { result.visible += 1 }
        if alpha < snapThreshold {
            if before.rgba[offset ..< offset + 4] != after.rgba[offset ..< offset + 4] {
                result.lowAlphaChanged += 1
            }
            continue
        }
        if alpha < 255 { result.snapped += 1 }
        var pixelMax = 0
        for channel in 0 ..< 3 {
            let old = Int(before.rgba[offset + channel])
            let new = Int(after.rgba[offset + channel])
            let overBlack = abs(new - old)
            let overWhite = abs((new + 255 - Int(after.rgba[offset + 3])) - (old + 255 - alpha))
            pixelMax = max(pixelMax, overBlack, overWhite)
        }
        result.maxLevels = max(result.maxLevels, pixelMax)
        if pixelMax > 2 { result.over2Levels += 1 }
    }
    return result
}

// MARK: - Measurement

func measure(label: String, raw: Data) {
    guard
        let source = CGImageSourceCreateWithData(raw as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return }
    var chosen: [String: Int] = [:]
    for edge in edgeLadder {
        let thumb = thumbnail(of: source, maxPixelSize: edge)!
        let snapped = snapNearOpaqueAlpha(thumb)
        let base = encodePNG(thumb).count
        let snap = encodePNG(snapped).count
        if chosen["base"] == nil, base < byteLimit { chosen["base"] = edge }
        if chosen["snap"] == nil, snap < byteLimit { chosen["snap"] = edge }
        let diff = compare(pixels(of: thumb), pixels(of: snapped))
        let delta = 100 * Double(snap - base) / Double(base)
        let bits = Double(base * 8) / Double(max(1, diff.visible))
        print(
            "\(label),\(edge),\(base),\(snap),\(String(format: "%.1f", delta)),\(String(format: "%.1f", bits)),"
                + "\(diff.snapped),\(diff.lowAlphaChanged),\(diff.maxLevels),\(diff.over2Levels)")
    }
    print("\(label),ladder,\(chosen["base"] ?? 0),\(chosen["snap"] ?? 0)")
}

func timeSnap() {
    for edge in [618, 300] {
        let raw = syntheticRaw(variant: 0, grain: 1, alpha: .smoothNoise)
        let source = CGImageSourceCreateWithData(raw as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)!
        let thumb = thumbnail(of: source, maxPixelSize: edge)!
        var millis: [Double] = []
        for _ in 0 ..< 20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = snapNearOpaqueAlpha(thumb)
            millis.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        millis.sort()
        let encoded = DispatchTime.now().uptimeNanoseconds
        _ = encodePNG(thumb)
        let encodeMillis = Double(DispatchTime.now().uptimeNanoseconds - encoded) / 1e6
        print(
            "timing,\(edge),snap median ms,\(String(format: "%.2f", millis[10])),"
                + "one PNG encode ms,\(String(format: "%.1f", encodeMillis))")
    }
}

// MARK: - Synthetic fixtures

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// How the model's near-opaque alpha is spread over the subject. M1 saw "250 to 254, never 255";
/// the `sheets` mode shows the real field is slowly varying around 253, so `smooth` and
/// `smoothWeakNoise` are the realistic ones and `iid` is the worst case the sheets rule out.
enum AlphaModel: String, CaseIterable {
    case constant254  // every subject pixel at 254
    case smooth  // 253 +- 1, slowly varying
    case smoothWeakNoise  // smooth, plus +-1 on one pixel in four
    case smoothNoise  // smooth, plus +-1 on every pixel
    case iid  // uniform 250...254 per pixel
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A flat-shaded emoji-like subject (outline, gradient, fur-like strokes, eyes, mouth) drawn
/// with CoreGraphics so its edges are anti-aliased. Variants differ in size and detail; variant 3
/// has no strokes at all (a flat emoji like `thank you`). Premultiplied RGBA, 1024 x 1024.
func drawSubject(variant: Int) -> [UInt8] {
    let side = 1024
    var buffer = [UInt8](repeating: 0, count: side * side * 4)
    var rng = SplitMix64(seed: 0xA11CE + UInt64(variant))
    let widthFraction = [0.92, 0.62, 0.80, 0.92][variant]
    let heightFraction = [0.88, 0.95, 0.70, 0.88][variant]
    let strokes = [900, 250, 1800, 0][variant]
    buffer.withUnsafeMutableBytes { bytes in
        let context = CGContext(
            data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let body = CGRect(
            x: 512 - 512 * widthFraction, y: 512 - 512 * heightFraction,
            width: 1024 * widthFraction, height: 1024 * heightFraction)
        let outline = CGColor(srgbRed: 0.18, green: 0.09, blue: 0.05, alpha: 1)
        for dx in [-0.28, 0.28] {  // ears
            let ear = CGRect(x: 512 + dx * body.width - 90, y: body.maxY - 150, width: 180, height: 180)
            context.setFillColor(outline)
            context.fillEllipse(in: ear)
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.55, blue: 0.5, alpha: 1))
            context.fillEllipse(in: ear.insetBy(dx: 18, dy: 18))
        }
        context.setFillColor(outline)
        context.fillEllipse(in: body)
        let inner = body.insetBy(dx: 18, dy: 18)
        context.saveGState()
        context.addEllipse(in: inner)
        context.clip()
        let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [
                CGColor(srgbRed: 1.0, green: 0.86, blue: 0.25, alpha: 1),
                CGColor(srgbRed: 0.93, green: 0.52, blue: 0.12, alpha: 1),
            ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 512, y: inner.maxY), end: CGPoint(x: 512, y: inner.minY), options: [])
        for _ in 0 ..< strokes {
            let x = CGFloat.random(in: inner.minX ... inner.maxX, using: &rng)
            let y = CGFloat.random(in: inner.minY ... inner.maxY, using: &rng)
            let shade = CGFloat.random(in: 0.55 ... 1.35, using: &rng)
            context.setStrokeColor(
                CGColor(srgbRed: min(1, 0.95 * shade), green: min(1, 0.6 * shade), blue: min(1, 0.15 * shade), alpha: 0.7))
            context.setLineWidth(CGFloat.random(in: 1.5 ... 4.5, using: &rng))
            context.move(to: CGPoint(x: x, y: y))
            context.addQuadCurve(
                to: CGPoint(x: x + CGFloat.random(in: -22 ... 22, using: &rng), y: y + CGFloat.random(in: -22 ... 22, using: &rng)),
                control: CGPoint(x: x + CGFloat.random(in: -14 ... 14, using: &rng), y: y + CGFloat.random(in: -14 ... 14, using: &rng)))
            context.strokePath()
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4))
        context.fillEllipse(
            in: CGRect(
                x: inner.minX + inner.width * 0.18, y: inner.maxY - inner.height * 0.3,
                width: inner.width * 0.3, height: inner.height * 0.12))
        context.restoreGState()
        for dx in [-0.17, 0.17] {  // eyes
            let eye = CGRect(x: 512 + dx * body.width - 55, y: 512 + 40, width: 110, height: 150)
            context.setFillColor(outline)
            context.fillEllipse(in: eye.insetBy(dx: -8, dy: -8))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: eye)
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.05, blue: 0.03, alpha: 1))
            context.fillEllipse(in: eye.insetBy(dx: 18, dy: 22))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: eye.midX - 6, y: eye.midY + 14, width: 24, height: 24))
        }
        context.setStrokeColor(outline)
        context.setLineWidth(12)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 512 - 110, y: 430))
        context.addQuadCurve(to: CGPoint(x: 512 + 110, y: 430), control: CGPoint(x: 512, y: 300))
        context.strokePath()
        context.setFillColor(CGColor(srgbRed: 0.97, green: 0.42, blue: 0.4, alpha: 0.55))
        for dx in [-0.3, 0.3] {  // cheeks
            context.fillEllipse(in: CGRect(x: 512 + dx * body.width - 50, y: 380, width: 100, height: 60))
        }
    }
    return buffer
}

/// Irwin-Hall sum of four uniforms (mean 2, sigma 0.577) scaled to `sigma`.
func gaussian(_ rng: inout SplitMix64, sigma: Double) -> Double {
    let sum = (0 ..< 4).reduce(0.0) { total, _ in total + Double.random(in: 0 ..< 1, using: &rng) }
    return (sum - 2) / 0.577 * sigma
}

/// A raw model-style PNG: straight (non-premultiplied) RGBA. Fully opaque subject pixels get
/// per-channel colour grain of `grain` levels (sigma) and a near-opaque alpha from `alpha`;
/// anti-aliased edge pixels keep their alpha.
func syntheticRaw(variant: Int, grain: Double, alpha model: AlphaModel) -> Data {
    let side = 1024
    var buffer = drawSubject(variant: variant)
    var rng = SplitMix64(seed: 0xBEEF + UInt64(variant) * 31 + UInt64(grain * 10))
    // Slowly varying field in -1...1: bilinear over a 9 x 9 grid of random values.
    let grid = (0 ..< 81).map { _ in Double.random(in: -1 ... 1, using: &rng) }
    func smooth(_ x: Int, _ y: Int) -> Double {
        let fx = Double(x) / Double(side - 1) * 8
        let fy = Double(y) / Double(side - 1) * 8
        let x0 = min(7, Int(fx)), y0 = min(7, Int(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let top = grid[y0 * 9 + x0] * (1 - tx) + grid[y0 * 9 + x0 + 1] * tx
        let bottom = grid[(y0 + 1) * 9 + x0] * (1 - tx) + grid[(y0 + 1) * 9 + x0 + 1] * tx
        return top * (1 - ty) + bottom * ty
    }
    for y in 0 ..< side {
        for x in 0 ..< side {
            let offset = (y * side + x) * 4
            let a = Int(buffer[offset + 3])
            if a == 0 { continue }
            for channel in 0 ..< 3 {  // un-premultiply to straight colour
                buffer[offset + channel] = UInt8(min(255, (Int(buffer[offset + channel]) * 255 + a / 2) / a))
            }
            guard a == 255 else { continue }
            if grain > 0 {
                for channel in 0 ..< 3 {
                    let value = Double(buffer[offset + channel]) + gaussian(&rng, sigma: grain)
                    buffer[offset + channel] = UInt8(max(0, min(255, value.rounded())))
                }
            }
            let base = Int((253 + smooth(x, y)).rounded())
            let value: Int
            switch model {
            case .constant254: value = 254
            case .smooth: value = base
            case .smoothWeakNoise: value = base + (Int.random(in: 0 ..< 4, using: &rng) == 0 ? Int.random(in: -1 ... 1, using: &rng) : 0)
            case .smoothNoise: value = base + Int.random(in: -1 ... 1, using: &rng)
            case .iid: value = Int.random(in: 250 ... 254, using: &rng)
            }
            buffer[offset + 3] = UInt8(max(250, min(254, value)))
        }
    }
    let provider = CGDataProvider(data: Data(buffer) as CFData)!
    let image = CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: sRGB,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return encodePNG(image)
}

// MARK: - Alpha structure from the contact sheets

// spike.swift composites each sticker over a light and a dark background (RGB.light 0xF2F2F7,
// RGB.dark 0x1C1C1E) in 300 px cells, five per row, so per channel
// (light - dark) = (1 - alpha) * (L - D) and the alpha deficit 255 - alpha can be read back
// for every pixel, to about half a level. Only the pixels deep inside the subject are kept.

let lightBackground: [Double] = [242, 242, 247]
let darkBackground: [Double] = [28, 28, 30]
let cellSize = 300

func deficits(light: Pixels, dark: Pixels, x0: Int, y0: Int) -> [Double] {
    var out = [Double](repeating: 0, count: cellSize * cellSize)
    for y in 0 ..< cellSize {
        for x in 0 ..< cellSize {
            let li = ((y0 + y) * light.width + x0 + x) * 4
            let di = ((y0 + y) * dark.width + x0 + x) * 4
            var sum = 0.0
            for channel in 0 ..< 3 {
                let diff = Double(light.rgba[li + channel]) - Double(dark.rgba[di + channel])
                sum += diff / (lightBackground[channel] - darkBackground[channel])
            }
            out[y * cellSize + x] = 255 * sum / 3
        }
    }
    return out
}

struct DeficitStats {
    var values: [Double] = []
    var neighbours1: [(Double, Double)] = []  // horizontal pairs, 1 px apart
    var neighbours5: [(Double, Double)] = []  // horizontal pairs, 5 px apart

    mutating func add(_ deficit: [Double]) {
        // Deep interior: this pixel and its 8 neighbours have a deficit between -1 and 7 levels.
        var inside = [Bool](repeating: false, count: cellSize * cellSize)
        for y in 1 ..< cellSize - 1 {
            for x in 1 ..< cellSize - 1 {
                inside[y * cellSize + x] = (-1 ... 1).allSatisfy { dy in
                    (-1 ... 1).allSatisfy { dx in
                        (-1.0 ... 7.0).contains(deficit[(y + dy) * cellSize + x + dx])
                    }
                }
            }
        }
        for y in 1 ..< cellSize - 1 {
            for x in 1 ..< cellSize - 1 where inside[y * cellSize + x] {
                let here = deficit[y * cellSize + x]
                values.append(here)
                if x + 1 < cellSize - 1, inside[y * cellSize + x + 1] { neighbours1.append((here, deficit[y * cellSize + x + 1])) }
                if x + 5 < cellSize - 1, inside[y * cellSize + x + 5] { neighbours5.append((here, deficit[y * cellSize + x + 5])) }
            }
        }
    }

    static func correlation(_ pairs: [(Double, Double)]) -> Double {
        let n = Double(pairs.count)
        let meanA = pairs.reduce(0) { $0 + $1.0 } / n
        let meanB = pairs.reduce(0) { $0 + $1.1 } / n
        var cross = 0.0, varA = 0.0, varB = 0.0
        for (a, b) in pairs {
            cross += (a - meanA) * (b - meanB)
            varA += (a - meanA) * (a - meanA)
            varB += (b - meanB) * (b - meanB)
        }
        return cross / (varA * varB).squareRoot()
    }

    func line(_ name: String) -> String {
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let std = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n).squareRoot()
        var histogram = [Int](repeating: 0, count: 8)
        for value in values { histogram[max(0, min(7, Int(value.rounded())))] += 1 }
        let shares = histogram.map { String(format: "%.2f", Double($0) / n) }.joined(separator: " ")
        return name.padding(toLength: 24, withPad: " ", startingAt: 0)
            + String(
                format: " n %d  mean %.2f  std %.2f  lag1 %.2f  lag5 %.2f  share of deficit 0..7: ",
                values.count, mean, std, Self.correlation(neighbours1), Self.correlation(neighbours5)) + shares
    }
}

func compositeCell(_ image: CGImage, background: [Double]) -> Pixels {
    var buffer = [UInt8](repeating: 0, count: cellSize * cellSize * 4)
    buffer.withUnsafeMutableBytes { bytes in
        let context = CGContext(
            data: bytes.baseAddress, width: cellSize, height: cellSize, bitsPerComponent: 8,
            bytesPerRow: cellSize * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: background[0] / 255, green: background[1] / 255, blue: background[2] / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: cellSize, height: cellSize))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: cellSize, height: cellSize))
    }
    return Pixels(width: cellSize, height: cellSize, rgba: buffer)
}

func sheetsCommand(directory: String?) {
    if let directory {
        var all = DeficitStats()
        for quality in ["low", "medium", "high"] {
            func load(_ name: String) -> Pixels {
                let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(directory)/\(quality)-\(name).png") as CFURL, nil)!
                return pixels(of: CGImageSourceCreateImageAtIndex(source, 0, nil)!)
            }
            let light = load("light"), dark = load("dark")
            var stats = DeficitStats()
            for index in 0 ..< 20 {  // sheet layout from spike.swift: gap 8, title 28, label 18
                let x0 = 8 + (index % 5) * 308
                let y0 = 36 + (index / 5) * 326
                stats.add(deficits(light: light, dark: dark, x0: x0, y0: y0))
            }
            print(stats.line("real \(quality)"))
            all.values += stats.values
            all.neighbours1 += stats.neighbours1
            all.neighbours5 += stats.neighbours5
        }
        print(all.line("real all"))
    }
    for model in AlphaModel.allCases {
        var stats = DeficitStats()
        for variant in 0 ..< 3 {
            let raw = syntheticRaw(variant: variant, grain: 1, alpha: model)
            let source = CGImageSourceCreateWithData(raw as CFData, nil)!
            // The sheets were drawn from the encoded sticker PNG, so round-trip it the same way.
            let sticker = CGImageSourceCreateImageAtIndex(
                CGImageSourceCreateWithData(encodePNG(thumbnail(of: source, maxPixelSize: 618)!) as CFData, nil)!, 0, nil)!
            stats.add(
                deficits(
                    light: compositeCell(sticker, background: lightBackground),
                    dark: compositeCell(sticker, background: darkBackground), x0: 0, y0: 0))
        }
        print(stats.line("synthetic \(model.rawValue)"))
    }
}

// MARK: - Main

let arguments = CommandLine.arguments
let header = "input,edge,baselineBytes,snapBytes,deltaPct,bitsPerVisiblePixel,snappedPixels,"
    + "lowAlphaPixelsChanged,maxCompositeLevels,pixelsOver2Levels"
if arguments.count >= 3, arguments[1] == "dir" {
    print(header)
    let directory = URL(fileURLWithPath: arguments[2])
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in files.sorted() where name.hasSuffix(".png") {
        if let raw = try? Data(contentsOf: directory.appendingPathComponent(name)) {
            measure(label: name, raw: raw)
        }
    }
} else if arguments.count >= 2, arguments[1] == "synthetic" {
    print(header)
    for variant in 0 ..< 4 {
        for grain in [0.0, 1.0, 2.0] {
            for model in AlphaModel.allCases {
                measure(label: "v\(variant)/grain\(Int(grain))/\(model.rawValue)", raw: syntheticRaw(variant: variant, grain: grain, alpha: model))
            }
        }
    }
    timeSnap()
} else if arguments.count >= 2, arguments[1] == "sheets" {
    sheetsCommand(directory: arguments.count >= 3 ? arguments[2] : nil)
} else {
    print("usage: alpha-snap dir <raw-png-dir> | synthetic | sheets [<sheet-dir>]")
}

// swiftlint:enable cyclomatic_complexity function_body_length
