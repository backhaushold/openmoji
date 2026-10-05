#!/usr/bin/env swift
//
// App icon and iMessage icon tooling (bead openmoji-98g.1). Replaces
// scripts/make-placeholder-icons.swift.
//
//   swift scripts/make-icons.swift generate [--n N] [--quality low|medium|high] [--out DIR] [--force]
//       PAID. Asks the OpenAI Images API for N candidate sticker icons (default 3,
//       never more than 4) and saves them as build/icons/candidate-<time>-<i>.png.
//       Needs OPENAI_API_KEY in the environment, injected by `op run`:
//         op run --env-file spikes/m1/op.env -- swift scripts/make-icons.swift generate
//       The key is sent only as the Authorization header. It is never printed, logged
//       or written, and `sk-...` text is scrubbed from error bodies before they are shown.
//       <out>/requests.log gets one line per request (time, status, seconds; no key).
//       With 5 or more lines already there the command refuses unless --force is given.
//
//   swift scripts/make-icons.swift render <candidate.png> [--background RRGGBB]
//       FREE. Trims the transparent sticker to its alpha bounding box and composites it,
//       opaque, over a background (a blue gradient, or the solid colour given) at every
//       slot of the icon sets, overwriting the PNGs in place. The Contents.json files
//       are the source of truth for which files and sizes exist (point size x scale).
//
//   swift scripts/make-icons.swift selftest [--keep]
//       FREE. Runs `render` on a synthetic sticker against a temporary copy of both icon
//       sets and checks every output: exact pixel size, no alpha channel, background in
//       the corners. Exits non-zero on any failure. --keep leaves the temp dir for a look.
//
// Foundation, CoreGraphics, ImageIO only; no third-party packages (NFR-7). Output PNGs
// are opaque (no alpha channel) as App Store Connect requires for icons, and rendering is
// deterministic. ICONS_TEST_ENDPOINT points `generate` at a loopback stub for
// scripts/test-make-icons.sh; any other host is refused, so it can never reach a real API
// by accident.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Configuration

private enum Config {
    /// Tech spec section 5.1 request fields, exactly (same as spikes/m1/spike.swift).
    static let model = "gpt-image-2.5-flare"
    static let realEndpoint = "https://api.openai.com/v1/images/generations"
    static let timeout: TimeInterval = 180
    static let defaultCount = 3
    static let maxCount = 4
    static let qualities = ["low", "medium", "high"]
    static let defaultQuality = "high"
    /// `generate` refuses to start when the request log already has this many lines.
    static let requestCap = 5

    /// The icon prompt. Edit this to change the artwork; nothing else depends on its wording.
    static let prompt = """
        A single cheerful emoji-style sticker icon: a glossy yellow smiley face with a big open-mouth grin \
        and one eye winking. Bold simple shapes, flat bright saturated colors, a soft highlight for the gloss. \
        A thick white die-cut sticker border all the way around the face, and a small peeled-up corner at the \
        lower right. Centered, with a little empty margin around the sticker. Transparent background. \
        No text, no letters, no numbers, no watermark, nothing else in the picture.
        """

    /// The icon sets, relative to the repository root. MessagesIcon is the extension's
    /// compiled app-icon set that Messages' + menu resolves (openmoji-98g.3); the
    /// stickersiconset still provides the loose PNGs and the App Store marketing image.
    static let iconSets = [
        "App/Assets.xcassets/AppIcon.appiconset",
        "MessagesExtension/Assets.xcassets/MessagesIcon.appiconset",
        "MessagesExtension/Assets.xcassets/iMessage App Icon.stickersiconset"
    ]
    /// The sticker is fitted inside a square of this fraction of the slot's shorter edge.
    static let stickerFraction = 0.8
    /// Alpha at or below this (of 255) does not count as sticker when trimming.
    static let trimAlphaThreshold: UInt8 = 8
    /// Default background: sky blue at the top to iOS blue at the bottom.
    static let gradientTop: [UInt8] = [0x5A, 0xC8, 0xFA]
    static let gradientBottom: [UInt8] = [0x00, 0x7A, 0xFF]
}

// MARK: - Small helpers

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func say(_ message: String) {
    print(message)
    fflush(stdout)
}

/// scripts/make-icons.swift -> repository root.
private func repositoryRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
}

/// Removes anything that looks like an API key from text taken from API responses.
private func redact(_ text: String, key: String?) -> String {
    var result = text
    if let key, !key.isEmpty { result = result.replacingOccurrences(of: key, with: "[redacted]") }
    if let regex = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9_\\-\\*\\.]{4,}") {
        result = regex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]"
        )
    }
    return result
}

private func fixed(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

private struct Arguments {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
}

/// A tiny parser: `valued` options take the next argument, `boolean` ones stand alone.
private func parseArguments(_ arguments: [String], valued: Set<String>, boolean: Set<String>) -> Arguments {
    var parsed = Arguments()
    var rest = arguments[...]
    while let argument = rest.popFirst() {
        if valued.contains(argument) {
            guard let value = rest.popFirst() else { fail("\(argument) needs a value") }
            parsed.values[argument] = value
        } else if boolean.contains(argument) {
            parsed.flags.insert(argument)
        } else if argument.hasPrefix("-") {
            fail("unknown option \(argument)\n\n\(helpText)")
        } else {
            parsed.positionals.append(argument)
        }
    }
    return parsed
}

// MARK: - Images

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func makeContext(width: Int, height: Int, alpha: CGImageAlphaInfo) -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: alpha.rawValue
    ) else { fail("could not create a \(width)x\(height) bitmap context") }
    context.interpolationQuality = .high
    return context
}

private func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fail("could not create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

/// 8-bit RGBA pixels, premultiplied, row 0 at the top.
private struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        let context = makeContext(width: width, height: height, alpha: .premultipliedLast)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { fail("could not read the pixels of a \(width)x\(height) image") }
        let rowBytes = context.bytesPerRow
        let raw = data.assumingMemoryBound(to: UInt8.self)
        var packed = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width * 4 { packed[row * width * 4 + column] = raw[row * rowBytes + column] }
        }
        bytes = packed
    }

    /// Red, green, blue, alpha of the pixel at column x, row y (0 is the top row).
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(bytes[offset ..< offset + 4])
    }

    /// The smallest rectangle holding every pixel with alpha above `threshold`, top-left origin.
    func opaqueBounds(threshold: UInt8) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where bytes[(y * width + x) * 4 + 3] > threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

// MARK: - render

private enum Background {
    case gradient
    case solid([UInt8])

    /// `RRGGBB`, with an optional leading `#`.
    static func parse(_ text: String) -> Background {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            fail("--background must be six hex digits like 5AC8FA, got \(text)")
        }
        return .solid([UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    func fill(_ context: CGContext, width: Int, height: Int) {
        switch self {
        case let .solid(rgb):
            context.setFillColor(cgColor(rgb))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .gradient:
            guard let gradient = CGGradient(
                colorsSpace: sRGB, colors: [cgColor(Config.gradientTop), cgColor(Config.gradientBottom)] as CFArray,
                locations: [0, 1]
            ) else { fail("could not create the background gradient") }
            // Core Graphics' y axis points up, so the top colour starts at y = height.
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: []
            )
        }
    }

    private func cgColor(_ rgb: [UInt8]) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1)
    }
}

private struct IconSet: Decodable {
    struct Slot: Decodable {
        let filename: String?
        let size: String
        /// Absent for the single-size universal app icon, which means 1x.
        let scale: String?
    }

    let images: [Slot]
}

/// One PNG to produce: where, and its exact size in pixels.
private struct Output {
    let url: URL
    let label: String
    let width: Int
    let height: Int
}

/// Splits "60x45" or "2x" style strings into numbers.
private func numbers(_ text: String) -> [Double] {
    text.split(separator: "x").compactMap { Double($0) }
}

/// Every slot that names a file, in the icon sets under `root`.
private func outputs(under root: URL) -> [Output] {
    var result: [Output] = []
    for relativePath in Config.iconSets {
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
            result.append(Output(
                url: directory.appending(path: filename),
                label: "\(relativePath)/\(filename)",
                width: Int((points[0] * scale).rounded()),
                height: Int((points[1] * scale).rounded())
            ))
        }
    }
    return result
}

/// Crops a sticker to its alpha bounding box. Nil when nothing in it is visible.
private func trimmed(_ image: CGImage) -> (image: CGImage, wasTrimmed: Bool)? {
    guard let bounds = Pixels(image).opaqueBounds(threshold: Config.trimAlphaThreshold) else { return nil }
    guard let cropped = image.cropping(to: bounds) else { fail("could not crop the sticker") }
    return (cropped, bounds.width != CGFloat(image.width) || bounds.height != CGFloat(image.height))
}

/// An opaque `width` x `height` image: the background with the sticker centered on it,
/// fitted inside a square of `stickerFraction` of the shorter edge, aspect preserved.
private func composite(sticker: CGImage, background: Background, width: Int, height: Int) -> CGImage {
    let context = makeContext(width: width, height: height, alpha: .noneSkipLast)
    background.fill(context, width: width, height: height)
    let box = Config.stickerFraction * Double(min(width, height))
    let scale = box / Double(max(sticker.width, sticker.height))
    let drawWidth = Double(sticker.width) * scale
    let drawHeight = Double(sticker.height) * scale
    context.draw(sticker, in: CGRect(
        x: (Double(width) - drawWidth) / 2, y: (Double(height) - drawHeight) / 2,
        width: drawWidth, height: drawHeight
    ))
    guard let image = context.makeImage() else { fail("could not render \(width)x\(height) image") }
    return image
}

/// Renders `candidate` into every slot of the icon sets under `root`.
@discardableResult
private func render(candidate: URL, background: Background, root: URL) -> [Output] {
    guard let loaded = loadImage(candidate) else { fail("cannot read an image at \(candidate.path)") }
    guard let (sticker, wasTrimmed) = trimmed(loaded) else {
        fail("\(candidate.lastPathComponent) is fully transparent: nothing to render")
    }
    if !wasTrimmed {
        say("warning: no transparent margin found; treating the whole image as the sticker")
    }
    let slots = outputs(under: root)
    for slot in slots {
        writePNG(composite(sticker: sticker, background: background, width: slot.width, height: slot.height), to: slot.url)
        say("\(slot.label)  \(slot.width)x\(slot.height)")
    }
    return slots
}

private func renderCommand(_ arguments: [String]) {
    let parsed = parseArguments(arguments, valued: ["--background"], boolean: [])
    guard parsed.positionals.count == 1 else { fail("render takes one candidate PNG\n\n\(helpText)") }
    let background = parsed.values["--background"].map(Background.parse) ?? .gradient
    render(candidate: URL(fileURLWithPath: parsed.positionals[0]), background: background, root: repositoryRoot())
}

// MARK: - generate

/// The loopback test hook; anything else is refused rather than silently ignored.
private func endpoint() -> URL {
    guard let override = ProcessInfo.processInfo.environment["ICONS_TEST_ENDPOINT"] else {
        return URL(string: Config.realEndpoint)!
    }
    guard let url = URL(string: override), ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
        fail("ICONS_TEST_ENDPOINT must point at 127.0.0.1 or localhost")
    }
    return url
}

private struct APIResult {
    var status = 0
    var seconds = 0.0
    var body = Data()
    var transportError: String?
}

private func send(key: String, count: Int, quality: String) async -> APIResult {
    var request = URLRequest(url: endpoint())
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload: [String: Any] = [
        "model": Config.model,
        "prompt": Config.prompt,
        "n": count,
        "size": "1024x1024",
        "quality": quality,
        "background": "transparent",
        "output_format": "png",
        "moderation": "auto"
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Config.timeout
    configuration.timeoutIntervalForResource = Config.timeout
    var result = APIResult()
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        result.body = data
        result.status = (response as? HTTPURLResponse)?.statusCode ?? 0
    } catch {
        result.transportError = "URLError \((error as? URLError)?.code.rawValue ?? 0)"
    }
    let elapsed = (clock.now - start).components
    result.seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    return result
}

private func requestLogLines(_ log: URL) -> Int {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
    return text.split(separator: "\n").count
}

private func appendRequestLog(_ log: URL, _ result: APIResult, count: Int, quality: String) {
    let status = result.transportError.map { "0 (\($0))" } ?? String(result.status)
    let line = "\(ISO8601DateFormatter().string(from: Date())) status=\(status) "
        + "seconds=\(fixed(result.seconds, 1)) n=\(count) quality=\(quality)\n"
    if let handle = try? FileHandle(forWritingTo: log) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: log, atomically: true, encoding: .utf8)
    }
}

/// A failed request's message, scrubbed of anything key-shaped.
private func errorText(_ result: APIResult, key: String) -> String {
    if let transport = result.transportError { return transport }
    let json = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]
    if let message = (json?["error"] as? [String: Any])?["message"] as? String {
        return redact(message, key: key)
    }
    return redact(String(bytes: result.body.prefix(300), encoding: .utf8) ?? "(unreadable body)", key: key)
}

private func saveCandidates(_ result: APIResult, into directory: URL, key: String) {
    let json = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]
    guard let items = json?["data"] as? [[String: Any]], !items.isEmpty else {
        fail("the response has no data[] images")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])
    for (offset, item) in items.enumerated() {
        guard let encoded = item["b64_json"] as? String, let png = Data(base64Encoded: encoded),
              png.prefix(4) == pngSignature
        else { fail("data[\(offset)] has no decodable PNG in b64_json") }
        let file = directory.appending(path: "candidate-\(stamp)-\(offset + 1).png")
        do { try png.write(to: file) } catch { fail("could not write \(file.path)") }
        say(file.path)
    }
    if let usage = json?["usage"],
       let data = try? JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys, .prettyPrinted]),
       let text = String(bytes: data, encoding: .utf8) {
        say("usage: \(redact(text, key: key))")
    }
}

private func generateCommand(_ arguments: [String]) async {
    let parsed = parseArguments(arguments, valued: ["--n", "--quality", "--out"], boolean: ["--force"])
    guard parsed.positionals.isEmpty else { fail("generate takes no arguments, only options\n\n\(helpText)") }
    let count = parsed.values["--n"].map { Int($0) ?? 0 } ?? Config.defaultCount
    guard (1 ... Config.maxCount).contains(count) else { fail("--n must be 1 to \(Config.maxCount)") }
    let quality = parsed.values["--quality"] ?? Config.defaultQuality
    guard Config.qualities.contains(quality) else { fail("--quality must be one of \(Config.qualities.joined(separator: ", "))") }
    guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
        fail("OPENAI_API_KEY is not set. Run this through `op run --env-file spikes/m1/op.env --` (see README).")
    }
    _ = endpoint() // refuse a bad test endpoint before anything is sent

    let directory = parsed.values["--out"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? repositoryRoot().appending(path: "build/icons", directoryHint: .isDirectory)
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
        fail("could not create \(directory.path)")
    }
    let log = directory.appending(path: "requests.log")
    let used = requestLogLines(log)
    if used >= Config.requestCap, !parsed.flags.contains("--force") {
        fail("refusing: \(log.path) already has \(used) requests (cap \(Config.requestCap)). Pass --force to spend more.")
    }

    say("requesting \(count) x \(quality) 1024x1024 icon candidates from \(Config.model)...")
    let result = await send(key: key, count: count, quality: quality)
    appendRequestLog(log, result, count: count, quality: quality)
    guard result.status == 200 else {
        fail("the request failed with status \(result.status): \(errorText(result, key: key))")
    }
    say("done in \(fixed(result.seconds, 1)) s")
    saveCandidates(result, into: directory, key: key)
}

// MARK: - selftest

private struct Checks {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    mutating func expect(_ condition: Bool, _ description: @autoclosure () -> String) {
        if condition { passed += 1 } else { failures.append(description()) }
    }
}

/// A transparent 1024x1024 image with a yellow disc inside a white ring, off-centre so
/// trimming matters. The ring's bounding box is x 100...699, y 300...799 (top-left origin).
private func syntheticSticker() -> CGImage {
    let context = makeContext(width: 1024, height: 1024, alpha: .premultipliedLast)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 100, y: 1024 - 800, width: 600, height: 500))
    context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 130, y: 1024 - 770, width: 540, height: 440))
    context.setFillColor(CGColor(srgbRed: 0.3, green: 0.15, blue: 0, alpha: 1))
    context.fillEllipse(in: CGRect(x: 250, y: 1024 - 600, width: 60, height: 80))
    context.fillEllipse(in: CGRect(x: 490, y: 1024 - 600, width: 60, height: 80))
    guard let image = context.makeImage() else { fail("could not draw the synthetic sticker") }
    return image
}

private func close(_ actual: [UInt8], _ expected: [UInt8], tolerance: Int) -> Bool {
    zip(actual.prefix(3), expected).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}

/// The colour type byte of a PNG's IHDR chunk: 2 is RGB, 6 is RGBA, 4 is grey with alpha.
private func pngColorType(_ file: Data) -> UInt8? {
    file.count > 25 && file.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) ? file[file.startIndex + 25] : nil
}

private func verify(_ slots: [Output], background: Background, into checks: inout Checks) {
    let corners: [(Int, Int)] = [(0, 0), (1, 0), (0, 1)]
    for slot in slots {
        guard let image = loadImage(slot.url), let file = try? Data(contentsOf: slot.url) else {
            checks.expect(false, "\(slot.label): file is missing or not an image")
            continue
        }
        checks.expect(
            image.width == slot.width && image.height == slot.height,
            "\(slot.label): \(image.width)x\(image.height), expected \(slot.width)x\(slot.height)"
        )
        checks.expect(pngColorType(file) == 2, "\(slot.label): not a plain RGB PNG (it may have an alpha channel)")
        let pixels = Pixels(image)
        checks.expect(pixels.pixel(0, 0)[3] == 255, "\(slot.label): corner pixel is not opaque")
        switch background {
        case let .solid(rgb):
            for (x, y) in corners + [(slot.width - 1, slot.height - 1)] {
                checks.expect(pixels.pixel(x, y).prefix(3).elementsEqual(rgb), "\(slot.label): corner (\(x), \(y)) is not the background")
            }
            let middle = pixels.pixel(slot.width / 2, slot.height / 2)
            checks.expect(!close(middle, rgb, tolerance: 30), "\(slot.label): the sticker is not at the centre")
        case .gradient:
            checks.expect(close(pixels.pixel(0, 0), Config.gradientTop, tolerance: 6), "\(slot.label): top corner is not the gradient start")
            checks.expect(close(pixels.pixel(0, slot.height - 1), Config.gradientBottom, tolerance: 6), "\(slot.label): bottom corner is not the gradient end")
        }
    }
}

private func selftestCommand(_ arguments: [String]) {
    let parsed = parseArguments(arguments, valued: [], boolean: ["--keep"])
    guard parsed.positionals.isEmpty else { fail("selftest takes no arguments\n\n\(helpText)") }
    let fileManager = FileManager.default
    let temp = fileManager.temporaryDirectory.appending(path: "openmoji-icons-selftest-\(UUID().uuidString)", directoryHint: .isDirectory)
    var checks = Checks()
    defer {
        if parsed.flags.contains("--keep") { say("kept \(temp.path)") } else { try? fileManager.removeItem(at: temp) }
    }

    // A scratch copy of the icon sets: the repository's PNGs are never touched.
    for relativePath in Config.iconSets {
        let destination = temp.appending(path: relativePath, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: repositoryRoot().appending(path: relativePath, directoryHint: .isDirectory), to: destination)
        } catch { fail("could not copy \(relativePath): \(error)") }
    }
    let candidate = temp.appending(path: "candidate.png")
    let sticker = syntheticSticker()
    writePNG(sticker, to: candidate)

    // Trimming finds the ring's box (allowing a pixel of anti-aliasing each side).
    if let bounds = Pixels(sticker).opaqueBounds(threshold: Config.trimAlphaThreshold) {
        checks.expect(
            abs(bounds.minX - 100) <= 1 && abs(bounds.minY - 300) <= 1
                && abs(bounds.width - 600) <= 2 && abs(bounds.height - 500) <= 2,
            "trim box \(bounds) is not about (100, 300, 600, 500)"
        )
    } else {
        checks.expect(false, "trim found nothing in the synthetic sticker")
    }

    let solid = Background.solid([0x33, 0x66, 0x99])
    let slots = render(candidate: candidate, background: solid, root: temp)
    checks.expect(slots.count >= 14, "only \(slots.count) slots found in the icon sets (expected 2 app icons and 12 iMessage icons)")
    verify(slots, background: solid, into: &checks)

    let first = slots.compactMap { try? Data(contentsOf: $0.url) }
    render(candidate: candidate, background: solid, root: temp)
    checks.expect(first == slots.compactMap { try? Data(contentsOf: $0.url) }, "rendering twice gave different bytes")

    render(candidate: candidate, background: .gradient, root: temp)
    verify(slots, background: .gradient, into: &checks)

    if checks.failures.isEmpty {
        say("selftest ok: \(checks.passed) checks passed")
    } else {
        checks.failures.forEach { FileHandle.standardError.write(Data("FAIL \($0)\n".utf8)) }
        fail("selftest: \(checks.failures.count) of \(checks.passed + checks.failures.count) checks failed")
    }
}

// MARK: - Entry point

private let helpText = """
    usage: swift scripts/make-icons.swift <command> [options]
      generate [--n 1-4] [--quality low|medium|high] [--out DIR] [--force]
                 PAID: candidate sticker icons into build/icons (needs OPENAI_API_KEY via op run)
      render <candidate.png> [--background RRGGBB]
                 free: composite the sticker onto every slot of the icon sets, in place
      selftest [--keep]
                 free: render a synthetic sticker into a temp copy of the icon sets and check it
    """

private func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "generate": await generateCommand(Array(arguments.dropFirst()))
    case "render": renderCommand(Array(arguments.dropFirst()))
    case "selftest": selftestCommand(Array(arguments.dropFirst()))
    default: fail(helpText)
    }
}

await main()
