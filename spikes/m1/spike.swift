// OpenMoji M1 generation spike (openmoji-6sl). Throwaway: not part of the app, the
// package or CI. Runs the tech spec section 9 evaluation set against the Images API,
// measures latency and usage cost, and renders contact sheets for scoring.
//
// Foundation, ImageIO and CoreGraphics only. The key is read from OPENAI_API_KEY in
// the environment (injected by `op run`) and is never printed, logged or written.
// See spikes/m1/README.md.

// A throwaway analysis script: function length, complexity and parameter-count rules
// don't fit it, and splitting it up would only obscure the one-pass flow.
// swiftlint:disable cyclomatic_complexity function_body_length function_parameter_count

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Configuration

enum Config {
    /// Hard cap on API requests across every invocation (counted in the ledger).
    static let requestCap = 75
    /// Tech spec section 5.1 request fields, exactly.
    static let model = "gpt-image-2.5-flare"
    static let endpoint: URL = {
        // Test hook for the local stub server only: loopback hosts are accepted, nothing else.
        let override = ProcessInfo.processInfo.environment["SPIKE_TEST_ENDPOINT"].flatMap { URL(string: $0) }
        if let override, ["127.0.0.1", "localhost"].contains(override.host ?? "") { return override }
        return URL(string: "https://api.openai.com/v1/images/generations")!
    }()
    /// Spec NFR-4 is 90 s; the spike allows longer so a slow run is measured, not cut off.
    static let timeout: TimeInterval = 180
    static let nfr4Seconds = 90.0
    /// GPT Image 2.5 token prices in USD per million tokens, as stated in tech spec
    /// section 1.2 (NFR-8 note). Re-check against OpenAI's pricing page before relying on them.
    static let textInPerMillion = 5.0
    static let imageInPerMillion = 8.0
    static let imageOutPerMillion = 30.0
    /// Tech spec section 7.1 ladder and limit.
    static let edgeLadder = [618, 560, 512, 448, 384, 300]
    static let byteLimit = 500_000
}

struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    static let dark = RGB(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0)
    static let light = RGB(red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF7 / 255.0)
    static let neutral = RGB(red: 0.5, green: 0.5, blue: 0.5)
}

// MARK: - Prompts and templates

struct PromptCase {
    let index: Int
    let slug: String
    let subject: String
    let note: String
}

enum Prompts {
    /// 200 characters exactly (FR-6 limit); checked at start-up.
    static let long200 = "a very tired astronaut cat floating in space, holding a giant cup of coffee, wearing mismatched socks and a party hat, "
        + "looking surprised that the moon is made of cheese wedges and tiny crispy crackers"

    static let all: [PromptCase] = [
        PromptCase(index: 1, slug: "grumpy-cat", subject: "grumpy cat", note: "spec: face"),
        PromptCase(index: 2, slug: "grandma-laughing", subject: "grandma laughing", note: "spec: face"),
        PromptCase(index: 3, slug: "taco", subject: "taco", note: "spec: object"),
        PromptCase(index: 4, slug: "rocket", subject: "rocket", note: "spec: object"),
        PromptCase(index: 5, slug: "brain-freeze", subject: "brain freeze", note: "spec: abstract"),
        PromptCase(index: 6, slug: "monday-mood", subject: "monday mood", note: "spec: abstract"),
        PromptCase(index: 7, slug: "happy-birthday", subject: "happy birthday", note: "spec: text-bait"),
        PromptCase(index: 8, slug: "thank-you", subject: "thank you", note: "spec: text-bait"),
        PromptCase(index: 9, slug: "fluffy-dog", subject: "fluffy dog", note: "spec: fine detail"),
        PromptCase(index: 10, slug: "curly-hair-girl", subject: "curly hair girl", note: "spec: fine detail"),
        PromptCase(index: 11, slug: "two-penguins-hugging", subject: "two penguins hugging", note: "spec: multi-subject"),
        PromptCase(index: 12, slug: "a", subject: "a", note: "spec: edge case, one letter"),
        PromptCase(index: 13, slug: "long-200", subject: long200, note: "spec: edge case, 200 characters"),
        PromptCase(index: 14, slug: "frog-coffee-emoji", subject: "\u{1F438}\u{2615}\u{FE0F}", note: "spec: edge case, emoji only"),
        PromptCase(index: 15, slug: "dads-burnt-pancakes", subject: "dad's burnt pancakes", note: "STAND-IN family in-joke"),
        PromptCase(index: 16, slug: "dog-stealing-socks", subject: "the dog stealing socks", note: "STAND-IN family in-joke"),
        PromptCase(index: 17, slug: "grandpas-fishing-hat", subject: "grandpa's fishing hat", note: "STAND-IN family in-joke"),
        PromptCase(index: 18, slug: "pizza-slice", subject: "pizza slice", note: "added: object, fine detail (toppings, cheese)"),
        PromptCase(index: 19, slug: "sleepy-sloth", subject: "sleepy sloth", note: "added: animal with fur, low-energy expression"),
        PromptCase(index: 20, slug: "thumbs-up", subject: "thumbs up", note: "added: hand gesture, classic emoji"),
    ]
}

enum Templates {
    /// Tech spec section 9, verbatim.
    static let v1 = """
        A single emoji-style sticker of {subject}.
        Style: modern flat emoji illustration, bold clean outlines, simple rounded shapes,
        bright saturated colors, soft cel shading, glossy highlight, friendly expression where a face applies.
        Composition: one subject, centered, filling about 85% of a square canvas, fully in frame, front-facing.
        Background: fully transparent. No scene, no ground, no drop shadow, no border, no frame.
        No text, letters, numbers, captions or watermarks.
        """

    /// Revised template, only used if v1 misses the bar on medium (see the findings doc).
    static let v2 = v1

    static func render(_ name: String, subject: String) -> String? {
        let base: String
        switch name {
        case "v1": base = v1
        case "v2": base = v2
        default: return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.replacingOccurrences(of: "{subject}", with: trimmed)
    }
}

// MARK: - Options

struct Options {
    var command = "help"
    var qualities = ["low", "medium", "high"]
    var prompts: [Int]?
    var template = "v1"
    var out = "spikes/m1/out"
    var results = "spikes/m1/results"
    var force = false
    var maxRequests = Config.requestCap

    var ledgerPath: String { results + "/requests.jsonl" }

    static func parse(_ args: [String]) -> Options? {
        var opts = Options()
        var rest = args[...]
        if let first = rest.first, !first.hasPrefix("--") {
            opts.command = first
            rest = rest.dropFirst()
        }
        while let flag = rest.popFirst() {
            if flag == "--force" {
                opts.force = true
                continue
            }
            guard let value = rest.popFirst() else { return nil }
            switch flag {
            case "--qualities": opts.qualities = value.split(separator: ",").map(String.init)
            case "--prompts":
                opts.prompts = value == "all" ? nil : value.split(separator: ",").compactMap { Int($0) }
            case "--template": opts.template = value
            case "--out": opts.out = value
            case "--results": opts.results = value
            case "--max-requests": opts.maxRequests = min(Int(value) ?? 0, Config.requestCap)
            default: return nil
            }
        }
        return opts
    }
}

// MARK: - Small helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func say(_ message: String) {
    print(message)
    fflush(stdout)
}

func ensureDirectory(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func pad(_ number: Int) -> String { number < 10 ? "0\(number)" : "\(number)" }

func fileName(_ prompt: PromptCase) -> String { "\(pad(prompt.index))-\(prompt.slug).png" }

func fixed(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

/// Removes anything that looks like an API key from text taken from API responses.
func redact(_ text: String, key: String?) -> String {
    var result = text
    if let key, !key.isEmpty { result = result.replacingOccurrences(of: key, with: "[redacted]") }
    if let regex = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9_\\-\\*\\.]{4,}") {
        result = regex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
    }
    return result
}

func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
}

// MARK: - Ledger

typealias Entry = [String: Any]

func readLedger(_ path: String) -> [Entry] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? Entry
    }
}

func appendLedger(_ path: String, _ entry: Entry) {
    guard
        let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
        var line = String(data: data, encoding: .utf8)
    else { fail("could not encode ledger entry") }
    line += "\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func ledgerHas(_ ledger: [Entry], template: String, quality: String, index: Int) -> Bool {
    ledger.contains {
        $0["template"] as? String == template && $0["quality"] as? String == quality
            && $0["promptIndex"] as? Int == index
    }
}

// MARK: - API

struct APIResult {
    var status = 0
    var seconds = 0.0
    var body = Data()
    var requestID: String?
    var processingMs: String?
    var transportError: String?
}

func sendRequest(session: URLSession, key: String, prompt: String, quality: String) async -> APIResult {
    var request = URLRequest(url: Config.endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Tech spec section 5.1: these fields and no others (no response_format).
    let payload: [String: Any] = [
        "model": Config.model,
        "prompt": prompt,
        "n": 1,
        "size": "1024x1024",
        "quality": quality,
        "background": "transparent",
        "output_format": "png",
        "moderation": "auto",
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

    var result = APIResult()
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let (data, response) = try await session.data(for: request)
        result.seconds = (clock.now - start).seconds
        result.body = data
        if let http = response as? HTTPURLResponse {
            result.status = http.statusCode
            result.requestID = http.value(forHTTPHeaderField: "x-request-id")
            result.processingMs = http.value(forHTTPHeaderField: "openai-processing-ms")
        }
    } catch {
        result.seconds = (clock.now - start).seconds
        let code = (error as? URLError)?.code.rawValue ?? 0
        result.transportError = "URLError \(code)"
    }
    return result
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

struct Usage {
    var raw: [String: Any] = [:]
    var cost: Double?
    var unpricedOutputTokens = 0
}

/// Cost from the response `usage` object and the section 1.2 token prices.
func priceUsage(_ usage: [String: Any]) -> Usage {
    let inputTotal = usage["input_tokens"] as? Int ?? 0
    let outputTotal = usage["output_tokens"] as? Int ?? 0
    let inputDetails = usage["input_tokens_details"] as? [String: Any]
    let outputDetails = usage["output_tokens_details"] as? [String: Any]
    let imageIn = inputDetails?["image_tokens"] as? Int ?? 0
    let textIn = inputDetails?["text_tokens"] as? Int ?? max(0, inputTotal - imageIn)
    let imageOut = outputDetails?["image_tokens"] as? Int ?? outputTotal
    let million = 1_000_000.0
    let cost = Double(textIn) * Config.textInPerMillion / million
        + Double(imageIn) * Config.imageInPerMillion / million
        + Double(imageOut) * Config.imageOutPerMillion / million
    return Usage(raw: usage, cost: cost, unpricedOutputTokens: max(0, outputTotal - imageOut))
}

// MARK: - Image helpers

func decodeImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func writePNG(_ image: CGImage, to path: String) {
    guard
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) { fail("cannot finalize \(path)") }
}

func encodePNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// Tech spec section 7.1: thumbnail from the original encoded bytes at each ladder
/// edge, first PNG under 500,000 bytes wins.
func makeSticker(from encoded: Data) -> (png: Data, edge: Int)? {
    guard
        let source = CGImageSourceCreateWithData(
            encoded as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        CGImageSourceGetCount(source) > 0
    else { return nil }
    for edge in Config.edgeLadder {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
            let png = encodePNG(thumbnail)
        else { return nil }
        if png.count < Config.byteLimit { return (png, thumbnail.width) }
    }
    return nil
}

struct Pixels {
    let width: Int
    let height: Int
    /// RGBA, 8 bits, premultiplied alpha.
    let data: [UInt8]

    func alpha(_ x: Int, _ y: Int) -> UInt8 { data[(y * width + x) * 4 + 3] }

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { pointer -> Bool in
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: pointer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        data = buffer
    }
}

// MARK: - Programmatic analysis (scoring items 2, 4, 5 support)

struct Analysis {
    var hasAlphaChannel = false
    var transparentFraction = 0.0
    var partialFraction = 0.0
    var cornerMaxAlpha = 0
    var borderTouchFraction = 0.0
    var bboxWidth = 0.0
    var bboxHeight = 0.0
    var centerDX = 0.0
    var centerDY = 0.0
    var lightEdgeFraction = 0.0

    /// Item 2 support: alpha channel present, corners fully clear, mostly transparent.
    var alphaOK: Bool { hasAlphaChannel && cornerMaxAlpha == 0 && transparentFraction >= 0.10 }
    /// Item 4 support: nothing touches the canvas edge and the subject is roughly centred.
    var framingOK: Bool {
        borderTouchFraction == 0 && abs(centerDX) <= 0.10 && abs(centerDY) <= 0.10
    }
}

func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: false
    default: true
    }
}

func analyze(_ image: CGImage) -> Analysis? {
    guard let pixels = Pixels(image) else { return nil }
    let width = pixels.width
    let height = pixels.height
    var result = Analysis()
    result.hasAlphaChannel = hasAlpha(image)

    var transparent = 0
    var partial = 0
    var minX = width
    var maxX = -1
    var minY = height
    var maxY = -1
    for y in 0 ..< height {
        for x in 0 ..< width {
            let alpha = pixels.alpha(x, y)
            if alpha == 0 { transparent += 1 } else if alpha < 255 { partial += 1 }
            if alpha > 16 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
    }
    let total = Double(width * height)
    result.transparentFraction = Double(transparent) / total
    result.partialFraction = Double(partial) / total

    let patch = 16
    for (cornerX, cornerY) in [(0, 0), (width - patch, 0), (0, height - patch), (width - patch, height - patch)] {
        for y in cornerY ..< cornerY + patch {
            for x in cornerX ..< cornerX + patch {
                result.cornerMaxAlpha = max(result.cornerMaxAlpha, Int(pixels.alpha(x, y)))
            }
        }
    }

    var touching = 0
    var ring = 0
    for y in 0 ..< height {
        for x in 0 ..< width where x < 2 || y < 2 || x >= width - 2 || y >= height - 2 {
            ring += 1
            if pixels.alpha(x, y) > 16 { touching += 1 }
        }
    }
    result.borderTouchFraction = Double(touching) / Double(ring)

    if maxX >= minX, maxY >= minY {
        result.bboxWidth = Double(maxX - minX + 1) / Double(width)
        result.bboxHeight = Double(maxY - minY + 1) / Double(height)
        result.centerDX = Double(minX + maxX + 1) / 2 / Double(width) - 0.5
        result.centerDY = Double(minY + maxY + 1) / 2 / Double(height) - 0.5
    }

    // Light fringe: boundary pixels (visible, with a fully clear 4-neighbour) whose
    // un-premultiplied colour is near white. A proxy for a halo on a dark bubble.
    var boundary = 0
    var light = 0
    for y in 1 ..< height - 1 {
        for x in 1 ..< width - 1 {
            let alpha = Int(pixels.alpha(x, y))
            guard alpha > 0 else { continue }
            let clear = pixels.alpha(x - 1, y) == 0 || pixels.alpha(x + 1, y) == 0
                || pixels.alpha(x, y - 1) == 0 || pixels.alpha(x, y + 1) == 0
            guard clear else { continue }
            boundary += 1
            let base = (y * width + x) * 4
            let red = min(255.0, Double(pixels.data[base]) * 255 / Double(alpha))
            let green = min(255.0, Double(pixels.data[base + 1]) * 255 / Double(alpha))
            let blue = min(255.0, Double(pixels.data[base + 2]) * 255 / Double(alpha))
            if (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255 > 0.85 { light += 1 }
        }
    }
    result.lightEdgeFraction = boundary == 0 ? 0 : Double(light) / Double(boundary)
    return result
}

// MARK: - Contact sheets

struct SheetCell {
    let label: String
    let image: CGImage?
    let background: RGB
}

func drawText(_ context: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
    let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
    guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(string), context)
}

func makeSheet(title: String, cells: [SheetCell], columns: Int, cellSize: Int) -> CGImage? {
    let gap = 8
    let labelHeight = 18
    let titleHeight = 28
    let rows = (cells.count + columns - 1) / columns
    let width = columns * (cellSize + gap) + gap
    let height = titleHeight + rows * (cellSize + labelHeight + gap) + gap
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(RGB.neutral.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    drawText(context, title, x: CGFloat(gap), y: CGFloat(height - titleHeight + 8), size: 15, color: white)
    context.interpolationQuality = .high
    for (position, cell) in cells.enumerated() {
        let column = position % columns
        let row = position / columns
        let originX = gap + column * (cellSize + gap)
        let top = titleHeight + gap + row * (cellSize + labelHeight + gap)
        let bottom = height - top - cellSize
        let rect = CGRect(x: originX, y: bottom, width: cellSize, height: cellSize)
        context.setFillColor(cell.background.cgColor)
        context.fill(rect)
        if let image = cell.image {
            context.draw(image, in: rect)
        } else {
            let red = CGColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1)
            drawText(context, "NO IMAGE", x: CGFloat(originX + 6), y: CGFloat(bottom + cellSize / 2), size: 14, color: red)
        }
        drawText(context, cell.label, x: CGFloat(originX), y: CGFloat(bottom - labelHeight + 5), size: 11, color: white)
    }
    return context.makeImage()
}

// MARK: - Commands

func runCommand(_ opts: Options) async {
    guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
        fail("OPENAI_API_KEY is not set. Run this through `op run --env-file spikes/m1/op.env --` (see README).")
    }
    guard Templates.render(opts.template, subject: "x") != nil else { fail("unknown template \(opts.template)") }
    let selected = Prompts.all.filter { opts.prompts?.contains($0.index) ?? true }
    ensureDirectory(opts.results)
    var ledger = readLedger(opts.ledgerPath)
    var planned: [(PromptCase, String)] = []
    for prompt in selected {
        for quality in opts.qualities
            where opts.force || !ledgerHas(ledger, template: opts.template, quality: quality, index: prompt.index) {
            planned.append((prompt, quality))
        }
    }
    let used = ledger.count
    say("template \(opts.template): \(planned.count) requests planned, \(used) already used, cap \(opts.maxRequests)")
    if used + planned.count > opts.maxRequests {
        fail("refusing: \(used) + \(planned.count) would exceed the cap of \(opts.maxRequests) requests")
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Config.timeout
    configuration.timeoutIntervalForResource = Config.timeout
    let session = URLSession(configuration: configuration)

    for (prompt, quality) in planned {
        guard ledger.count < opts.maxRequests else { fail("request cap reached") }
        guard let text = Templates.render(opts.template, subject: prompt.subject) else { continue }
        let result = await sendRequest(session: session, key: key, prompt: text, quality: quality)
        var entry = record(result: result, prompt: prompt, quality: quality, opts: opts, key: key)
        if result.status == 200 { saveOutputs(result: result, prompt: prompt, quality: quality, opts: opts, entry: &entry) }
        appendLedger(opts.ledgerPath, entry)
        ledger.append(entry)
        say(summaryLine(entry, number: ledger.count, cap: opts.maxRequests))
    }
}

func record(result: APIResult, prompt: PromptCase, quality: String, opts: Options, key: String) -> Entry {
    var entry: Entry = [
        "time": ISO8601DateFormatter().string(from: Date()),
        "template": opts.template,
        "quality": quality,
        "promptIndex": prompt.index,
        "prompt": prompt.subject,
        "status": result.status,
        "seconds": result.seconds,
    ]
    if let id = result.requestID { entry["requestID"] = id }
    if let ms = result.processingMs { entry["processingMs"] = ms }
    if let transport = result.transportError { entry["transportError"] = transport }
    let json = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]
    if result.status != 200, let error = json?["error"] as? [String: Any] {
        entry["errorCode"] = error["code"] as? String ?? "none"
        entry["errorType"] = error["type"] as? String ?? "none"
        entry["errorMessage"] = redact(error["message"] as? String ?? "", key: key)
    }
    if let usage = json?["usage"] as? [String: Any] {
        let priced = priceUsage(usage)
        entry["usage"] = priced.raw
        entry["costUSD"] = priced.cost
        entry["unpricedOutputTokens"] = priced.unpricedOutputTokens
    }
    for field in ["background", "output_format", "quality", "size"] {
        if let value = json?[field] as? String { entry["echo_\(field)"] = value }
    }
    return entry
}

func saveOutputs(result: APIResult, prompt: PromptCase, quality: String, opts: Options, entry: inout Entry) {
    let json = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]
    guard
        let items = json?["data"] as? [[String: Any]],
        let encoded = items.first?["b64_json"] as? String,
        let raw = Data(base64Encoded: encoded)
    else {
        entry["problem"] = "missing or undecodable b64_json"
        return
    }
    let rawDirectory = "\(opts.out)/raw/\(opts.template)/\(quality)"
    ensureDirectory(rawDirectory)
    try? raw.write(to: URL(fileURLWithPath: "\(rawDirectory)/\(fileName(prompt))"))
    entry["rawBytes"] = raw.count
}

func summaryLine(_ entry: Entry, number: Int, cap: Int) -> String {
    let index = entry["promptIndex"] as? Int ?? 0
    let quality = entry["quality"] as? String ?? "?"
    let status = entry["status"] as? Int ?? 0
    let seconds = entry["seconds"] as? Double ?? 0
    var line = "[\(number)/\(cap)] \(quality) #\(pad(index)) status \(status) \(fixed(seconds, 1))s"
    if let cost = entry["costUSD"] as? Double { line += " cost $\(fixed(cost, 4))" }
    if let code = entry["errorCode"] as? String { line += " error \(code)" }
    if let transport = entry["transportError"] as? String { line += " \(transport)" }
    if let problem = entry["problem"] as? String { line += " \(problem)" }
    return line
}

func renderCommand(_ opts: Options) {
    var rows = [
        "template,quality,index,slug,rawAlpha,transparentFrac,partialFrac,cornerMaxAlpha,borderTouchFrac,"
            + "bboxW,bboxH,centerDX,centerDY,lightEdgeFrac,alphaOK,framingOK,stickerEdge,stickerBytes,stickerAlpha",
    ]
    for quality in opts.qualities {
        let rawDirectory = "\(opts.out)/raw/\(opts.template)/\(quality)"
        let stickerDirectory = "\(opts.out)/sticker/\(opts.template)/\(quality)"
        ensureDirectory(stickerDirectory)
        var cells: [(PromptCase, CGImage?)] = []
        for prompt in Prompts.all where opts.prompts?.contains(prompt.index) ?? true {
            let rawURL = URL(fileURLWithPath: "\(rawDirectory)/\(fileName(prompt))")
            guard
                let raw = try? Data(contentsOf: rawURL), let rawImage = decodeImage(raw),
                let analysis = analyze(rawImage), let sticker = makeSticker(from: raw),
                let stickerImage = decodeImage(sticker.png)
            else {
                cells.append((prompt, nil))
                continue
            }
            try? sticker.png.write(to: URL(fileURLWithPath: "\(stickerDirectory)/\(fileName(prompt))"))
            cells.append((prompt, stickerImage))
            rows.append(analysisRow(opts, quality, prompt, analysis, sticker, stickerImage))
        }
        writeSheets(opts: opts, quality: quality, cells: cells)
    }
    ensureDirectory(opts.results)
    let path = "\(opts.results)/analysis-\(opts.template).csv"
    let existing = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    let merged = Array(Set(existing.dropFirst() + rows.dropFirst())).sorted()
    try? ([rows[0]] + merged).joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    say("rendered \(opts.template) sheets under \(opts.out)/sheets and analysis to \(path)")
}

func analysisRow(
    _ opts: Options, _ quality: String, _ prompt: PromptCase, _ analysis: Analysis,
    _ sticker: (png: Data, edge: Int), _ stickerImage: CGImage
) -> String {
    let fields: [String] = [
        opts.template, quality, pad(prompt.index), prompt.slug,
        "\(analysis.hasAlphaChannel)", fixed(analysis.transparentFraction, 3), fixed(analysis.partialFraction, 3),
        "\(analysis.cornerMaxAlpha)", fixed(analysis.borderTouchFraction, 3),
        fixed(analysis.bboxWidth, 2), fixed(analysis.bboxHeight, 2),
        fixed(analysis.centerDX, 3), fixed(analysis.centerDY, 3), fixed(analysis.lightEdgeFraction, 3),
        "\(analysis.alphaOK)", "\(analysis.framingOK)", "\(sticker.edge)", "\(sticker.png.count)",
        "\(hasAlpha(stickerImage))",
    ]
    return fields.joined(separator: ",")
}

func writeSheets(opts: Options, quality: String, cells: [(PromptCase, CGImage?)]) {
    let directory = "\(opts.out)/sheets/\(opts.template)"
    ensureDirectory(directory)
    func make(_ background: RGB, name: String) {
        let sheetCells = cells.map { SheetCell(label: "\(pad($0.0.index)) \($0.0.slug)", image: $0.1, background: background) }
        if let sheet = makeSheet(title: "\(opts.template) \(quality) \(name)", cells: sheetCells, columns: 5, cellSize: 300) {
            writePNG(sheet, to: "\(directory)/\(quality)-\(name).png")
        }
    }
    make(.dark, name: "dark")
    make(.light, name: "light")
    let small = cells.map { SheetCell(label: pad($0.0.index), image: $0.1, background: .dark) }
        + cells.map { SheetCell(label: pad($0.0.index), image: $0.1, background: .light) }
    if let sheet = makeSheet(title: "\(opts.template) \(quality) 100 px, dark then light", cells: small, columns: 10, cellSize: 100) {
        writePNG(sheet, to: "\(directory)/\(quality)-small.png")
    }
}

func summaryCommand(_ opts: Options) {
    let ledger = readLedger(opts.ledgerPath)
    say("requests in ledger: \(ledger.count) of cap \(Config.requestCap)")
    let scores = readScores(opts.results + "/scores.csv")
    for template in Set(ledger.compactMap { $0["template"] as? String }).sorted() {
        for quality in ["low", "medium", "high"] {
            let entries = ledger.filter { $0["template"] as? String == template && $0["quality"] as? String == quality }
            guard !entries.isEmpty else { continue }
            say(summarize(template: template, quality: quality, entries: entries, scores: scores))
        }
    }
}

func summarize(template: String, quality: String, entries: [Entry], scores: [String: [Int]]) -> String {
    let ok = entries.filter { $0["status"] as? Int == 200 }
    let refused = entries.filter { ($0["errorCode"] as? String) == "moderation_blocked" }
    let other = entries.count - ok.count - refused.count
    let seconds = ok.compactMap { $0["seconds"] as? Double }
    let costs = ok.compactMap { $0["costUSD"] as? Double }
    var lines = ["\(template) \(quality): \(entries.count) requests, \(ok.count) ok, \(refused.count) refused, \(other) other errors"]
    if let p50 = percentile(seconds, 0.5), let p90 = percentile(seconds, 0.9), let slowest = seconds.max() {
        let over = seconds.filter { $0 > Config.nfr4Seconds }.count
        lines.append("  latency p50 \(fixed(p50, 1))s p90 \(fixed(p90, 1))s max \(fixed(slowest, 1))s, over \(Int(Config.nfr4Seconds))s: \(over)")
    }
    if !costs.isEmpty {
        let mean = costs.reduce(0, +) / Double(costs.count)
        lines.append("  cost mean $\(fixed(mean, 4)) max $\(fixed(costs.max() ?? 0, 4)) total $\(fixed(costs.reduce(0, +), 4))")
    }
    let rows = scores.filter { $0.key.hasPrefix("\(template),\(quality),") }.map(\.value)
    if !rows.isEmpty {
        let perItem = (0 ..< 4).map { item in rows.filter { $0[item] == 1 }.count }
        let allFour = rows.filter { $0[0 ..< 4].allSatisfy { $0 == 1 } }.count
        let halo = rows.filter { $0[4] == 1 }.count
        lines.append("  scored \(rows.count): items 1-4 pass \(perItem), all four \(allFour), halo \(halo)")
    }
    return lines.joined(separator: "\n")
}

/// scores.csv: template,quality,index,i1,i2,i3,i4,i5,note. Items 1-4: 1 = pass. Item 5: 1 = halo seen.
func readScores(_ path: String) -> [String: [Int]] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var scores: [String: [Int]] = [:]
    for line in text.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 8 else { continue }
        scores["\(fields[0]),\(fields[1]),\(fields[2])"] = fields[3 ... 7].map { Int($0) ?? 0 }
    }
    return scores
}

/// Free self-test: synthetic images through analysis, processing and contact sheets.
func selftestCommand(_ opts: Options) {
    var test = opts
    test.template = "selftest"
    test.qualities = ["low"]
    test.prompts = [1, 2, 3]
    let directory = "\(test.out)/raw/selftest/low"
    ensureDirectory(directory)
    for (index, mode) in [(1, "good"), (2, "cropped"), (3, "opaque")] {
        guard
            let prompt = Prompts.all.first(where: { $0.index == index }),
            let image = syntheticImage(mode), let data = encodePNG(image)
        else { fail("selftest image failed") }
        try? data.write(to: URL(fileURLWithPath: "\(directory)/\(fileName(prompt))"))
    }
    renderCommand(test)
    say((try? String(contentsOfFile: "\(test.results)/analysis-selftest.csv", encoding: .utf8)) ?? "")
    precondition(Templates.render("v1", subject: "taco")?.contains("emoji-style sticker of taco.") == true)
    say("selftest done")
}

func syntheticImage(_ mode: String) -> CGImage? {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    if mode == "opaque" {
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }
    context.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1))
    let rect = mode == "cropped" ? CGRect(x: -80, y: 100, width: 700, height: 700) : CGRect(x: 100, y: 100, width: 824, height: 824)
    context.fillEllipse(in: rect)
    return context.makeImage()
}

let helpText = """
    usage: swift spikes/m1/spike.swift <command> [options]
      run       send requests (needs OPENAI_API_KEY via op run)   --qualities low,medium,high --prompts 1,2|all --template v1|v2 --force
      render    process raw PNGs, write stickers, analysis CSV and contact sheets (free)
      summary   latency, cost and score statistics from the ledger and scores.csv (free)
      selftest  synthetic images through the processing and sheet code (free)
    options: --out spikes/m1/out  --results spikes/m1/results  --max-requests N (never above \(Config.requestCap))
    """

func main() async {
    precondition(Prompts.long200.count == 200, "long prompt must be exactly 200 characters")
    guard let opts = Options.parse(Array(CommandLine.arguments.dropFirst())) else { fail(helpText) }
    switch opts.command {
    case "run": await runCommand(opts)
    case "render": renderCommand(opts)
    case "summary": summaryCommand(opts)
    case "selftest": selftestCommand(opts)
    default: say(helpText)
    }
}

await main()

// swiftlint:enable cyclomatic_complexity function_body_length function_parameter_count
