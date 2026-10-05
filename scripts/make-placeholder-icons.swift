#!/usr/bin/env swift
//
// Generates the PLACEHOLDER icon PNGs for both targets (bead openmoji-yyw).
// SUPERSEDED by scripts/make-icons.swift (openmoji-98g.1), which renders the real artwork; kept for reference.
//
// For every image slot that names a file in the two Contents.json files below,
// this renders an opaque amber square/rectangle with a dark "OM" glyph at the
// slot's exact pixel size (point size x scale) and writes it next to the
// Contents.json. The JSON is the source of truth for which files and sizes
// exist, so edit the JSON first if a slot is added.
//
// Built-in macOS frameworks only (CoreGraphics, CoreText, ImageIO); no third-party
// packages (NFR-7). Output is opaque (no alpha channel) as App Store Connect
// requires for icons. Re-running overwrites the PNGs byte-for-byte reproducibly.
//
// Usage, from anywhere:  swift scripts/make-placeholder-icons.swift
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct IconSet: Decodable {
    struct Slot: Decodable {
        let filename: String?
        let size: String
        /// Absent for the single-size universal app icon, which means 1x.
        let scale: String?
    }

    let images: [Slot]
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Splits "60x45" or "2x" style strings into numbers.
private func numbers(_ text: String) -> [Double] {
    text.split(separator: "x").compactMap { Double($0) }
}

private func renderPlaceholder(width: Int, height: Int) -> CGImage {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else { fail("could not create a \(width)x\(height) bitmap context") }

    context.setFillColor(CGColor(srgbRed: 1.0, green: 0.78, blue: 0.18, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let fontSize = CGFloat(min(width, height)) * 0.5
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
            CGColor(srgbRed: 0.25, green: 0.15, blue: 0.0, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "OM", attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(
        x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
        y: (CGFloat(height) - bounds.height) / 2 - bounds.minY
    )
    CTLineDraw(line, context)

    guard let image = context.makeImage() else { fail("could not render \(width)x\(height) image") }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fail("could not create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

// scripts/make-placeholder-icons.swift -> repository root
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let iconSets = [
    "App/Assets.xcassets/AppIcon.appiconset",
    "MessagesExtension/Assets.xcassets/iMessage App Icon.stickersiconset"
]

for relativePath in iconSets {
    let directory = root.appending(path: relativePath, directoryHint: .isDirectory)
    let manifest = directory.appending(path: "Contents.json")
    guard let data = try? Data(contentsOf: manifest),
          let iconSet = try? JSONDecoder().decode(IconSet.self, from: data)
    else { fail("cannot read \(manifest.path)") }

    for slot in iconSet.images {
        guard let filename = slot.filename else { continue }
        let points = numbers(slot.size)
        let scaleText = slot.scale ?? "1x"
        guard points.count == 2, let scale = numbers(scaleText).first else {
            fail("bad size/scale in \(manifest.path): \(slot.size) @ \(scaleText)")
        }
        let width = Int((points[0] * scale).rounded())
        let height = Int((points[1] * scale).rounded())
        writePNG(renderPlaceholder(width: width, height: height), to: directory.appending(path: filename))
        print("\(relativePath)/\(filename)  \(width)x\(height)")
    }
}
