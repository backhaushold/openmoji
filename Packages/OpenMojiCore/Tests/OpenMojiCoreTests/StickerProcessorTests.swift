import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenMojiCore

// Fixtures are generated in code (no committed binaries). The NFR-1 limit and
// the FR-14 ladder come from tech spec §7.1 / ADR-0004.

@Suite struct StickerProcessorTests {
    @Test func transparentSquareSourceYields618PixelPngUnderLimitWithAlpha() throws {
        let source = try Fixture.circlePNG(width: 1024, height: 1024)

        let result = try makeSticker(from: source)

        #expect(result.edge == 618)
        #expect(result.png.count < 500_000)
        let decoded = try Fixture.decodeRGBA(result.png)
        #expect(decoded.width == 618)
        #expect(decoded.height == 618)
        #expect(decoded.hasAlphaChannel)
        #expect(decoded.alpha(x: 0, y: 0) == 0)  // corner stays transparent
        #expect(decoded.alpha(x: 309, y: 309) == 255)  // circle centre stays opaque
    }

    @Test func highEntropyNoiseStepsDownToAnEdgeInTheLadderAtOrAbove300() throws {
        let source = try Fixture.noisePNG(width: 1024, height: 1024)
        #expect(source.count > 500_000)  // the fixture really is incompressible

        let result = try makeSticker(from: source)

        #expect(result.png.count < 500_000)
        #expect(stickerEdgeLadder.contains(result.edge))
        #expect(result.edge >= 300)
        #expect(result.edge < 618)  // 618 alone cannot fit noise, so we stepped down
        let decoded = try Fixture.decodeRGBA(result.png)
        #expect(decoded.width == result.edge)
        #expect(decoded.height == result.edge)
    }

    @Test func nonSquareSourceIsPaddedToATransparentSquare() throws {
        let source = try Fixture.circlePNG(width: 1024, height: 512)

        let result = try makeSticker(from: source)

        #expect(result.edge == 618)
        let decoded = try Fixture.decodeRGBA(result.png)
        #expect(decoded.width == 618)
        #expect(decoded.height == 618)
        // Content is 618 x 309, centred: the bands above and below are transparent padding.
        #expect(decoded.alpha(x: 309, y: 10) == 0)
        #expect(decoded.alpha(x: 309, y: 607) == 0)
        #expect(decoded.alpha(x: 309, y: 309) == 255)
    }

    @Test func opaqueSourceIsKeptAndFlaggedForTheWarning() throws {
        let source = try Fixture.opaquePNG(width: 1024, height: 1024)

        let result = try buildSticker(from: source)

        #expect(result.isOpaque)  // makeSticker logs a warning when this is set
        #expect(result.edge == 618)
        #expect(result.png.count < 500_000)
        let plain = try makeSticker(from: source)  // kept, not rejected
        #expect(plain.edge == 618)
        #expect(plain.png == result.png)
    }

    @Test func transparentSourceIsNotFlaggedOpaque() throws {
        let source = try Fixture.circlePNG(width: 1024, height: 1024)

        #expect(try buildSticker(from: source).isOpaque == false)
    }

    @Test func corruptDataThrowsProcessingFailed() {
        let garbage = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

        #expect(throws: GenerationError.processingFailed) {
            try makeSticker(from: garbage)
        }
        #expect(throws: GenerationError.processingFailed) {
            try makeSticker(from: Data())
        }
    }

    @Test func throwsInsteadOfShippingAnOversizedStickerWhenTheFloorDoesNotFit() throws {
        let source = try Fixture.circlePNG(width: 1024, height: 1024)

        #expect(throws: GenerationError.processingFailed) {
            try buildSticker(from: source, byteLimit: 1)
        }
    }
}

// MARK: - Fixtures

private enum Fixture {
    struct FixtureError: Error {}

    struct Decoded {
        let width: Int
        let height: Int
        let hasAlphaChannel: Bool
        let rgba: [UInt8]  // premultiplied RGBA, row-major, top row first

        func alpha(x: Int, y: Int) -> UInt8 { rgba[(y * width + x) * 4 + 3] }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An opaque-coloured circle on a fully transparent background.
    static func circlePNG(width: Int, height: Int) throws -> Data {
        try draw(width: width, height: height, alpha: .premultipliedLast) { context in
            let side = CGFloat(min(width, height))
            let rect = CGRect(
                x: (CGFloat(width) - side) / 2 + side * 0.1,
                y: (CGFloat(height) - side) / 2 + side * 0.1,
                width: side * 0.8, height: side * 0.8)
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.7, blue: 0.1, alpha: 1))
            context.fillEllipse(in: rect)
        }
    }

    /// A solid image with no alpha channel at all.
    static func opaquePNG(width: Int, height: Int) throws -> Data {
        try draw(width: width, height: height, alpha: .noneSkipLast) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Deterministic RGBA noise (straight alpha) that PNG's deflate cannot shrink.
    static func noisePNG(width: Int, height: Int) throws -> Data {
        var generator = SplitMix64(seed: 0x0123_4567_89AB_CDEF)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: generator.next())
        }
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: sRGB,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw FixtureError() }
        return try encodePNG(image)
    }

    static func draw(
        width: Int, height: Int, alpha: CGImageAlphaInfo,
        _ body: (CGContext) -> Void
    ) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB, bitmapInfo: alpha.rawValue)
        else { throw FixtureError() }
        body(context)
        guard let image = context.makeImage() else { throw FixtureError() }
        return try encodePNG(image)
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw FixtureError() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError() }
        return data as Data
    }

    /// Full decode is fine here: this is the test oracle, not the code under test.
    static func decodeRGBA(_ png: Data) throws -> Decoded {
        guard
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let pixels = context.data
        else { throw FixtureError() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = UnsafeBufferPointer(
            start: pixels.assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4)
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        return Decoded(
            width: image.width, height: image.height, hasAlphaChannel: hasAlpha,
            rgba: Array(buffer))
    }
}

private struct SplitMix64: RandomNumberGenerator {
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
