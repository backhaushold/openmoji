import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Sticker processing (tech spec §7.1, ADR-0004; FR-13, FR-14, NFR-1, NFR-5).
///
/// Turns the encoded image from OpenAI into a Messages-compliant PNG: under
/// 500,000 bytes, square, at the largest ladder edge that fits (never below
/// 300 px). Every candidate is a fresh ImageIO thumbnail of the *original*
/// encoded bytes, so quality never compounds and a full-size bitmap is never
/// decoded here.

/// Candidate edges in pixels, largest first (FR-14; ADR-0004).
let stickerEdgeLadder = [618, 560, 512, 448, 384, 300]

/// The hard Messages limit (NFR-1): the PNG must be strictly smaller than this.
let stickerByteLimit = 500_000

private let logger = Logger(subsystem: "com.backhaushold.openmoji", category: "StickerProcessor")

/// Converts encoded image bytes (normally the 1024 x 1024 PNG from OpenAI) into
/// sticker PNG data and the edge length, in pixels, of its square canvas.
///
/// Throws `GenerationError.processingFailed` (tech spec §6) for undecodable input or if
/// even the 300 px floor does not fit under 500 KB.
public func makeSticker(from encoded: Data) throws -> (png: Data, edge: Int) {
    let sticker = try buildSticker(from: encoded)
    if sticker.isOpaque {
        // Under `background: transparent` the model should return alpha; M1
        // tells us whether it ever doesn't. Kept regardless (tech spec §7.1.7).
        logger.warning("Sticker source has no alpha channel; keeping it opaque")
    }
    return (sticker.png, sticker.edge)
}

struct BuiltSticker {
    let png: Data
    let edge: Int
    /// The thumbnail the PNG came from carried no alpha channel.
    let isOpaque: Bool
}

/// `makeSticker` with the ladder and size limit injectable for tests.
func buildSticker(
    from encoded: Data,
    edges: [Int] = stickerEdgeLadder,
    byteLimit: Int = stickerByteLimit
) throws -> BuiltSticker {
    // Step 1: a source that decodes nothing until a thumbnail is requested.
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard
        let source = CGImageSourceCreateWithData(encoded as CFData, sourceOptions),
        CGImageSourceGetCount(source) > 0
    else { throw GenerationError.processingFailed }

    for edge in edges {
        // Step 2: thumbnail from the original source at this edge.
        guard let thumbnail = thumbnail(of: source, maxPixelSize: edge) else {
            throw GenerationError.processingFailed
        }
        // Step 3: square guard.
        let square = try squared(thumbnail)
        // Step 4: encode.
        let png = try encodePNG(square)
        // Step 5: first candidate under the limit wins.
        if png.count < byteLimit {
            return BuiltSticker(
                png: png, edge: square.width, isOpaque: !thumbnail.hasAlphaChannel)
        }
    }
    // Step 6: floor did not fit; never ship an invalid sticker.
    throw GenerationError.processingFailed
}

private func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> CGImage? {
    let options =
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
}

/// Returns `image` unchanged if square, else centres it on a transparent
/// square canvas whose side is the longer edge.
private func squared(_ image: CGImage) throws -> CGImage {
    guard image.width != image.height else { return image }
    let side = max(image.width, image.height)
    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw GenerationError.processingFailed }
    // A new context is zero-filled, i.e. fully transparent.
    context.draw(
        image,
        in: CGRect(
            x: (side - image.width) / 2, y: (side - image.height) / 2,
            width: image.width, height: image.height))
    guard let padded = context.makeImage() else { throw GenerationError.processingFailed }
    return padded
}

private func encodePNG(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
    else { throw GenerationError.processingFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw GenerationError.processingFailed
    }
    return data as Data
}

extension CGImage {
    fileprivate var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
