import Foundation
import Messages
import OpenMojiCore
import Testing
import UIKit

// The Preview's temp file (tech spec §10): the processed PNG written for its
// `MSSticker`, and removed again.

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenMojiPreviewTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct PreviewFileTests {
    @Test func writesThePNGBytesToAFileInTheDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sticker = makeProcessedSticker()

        let url = try PreviewFile.write(sticker, in: directory)

        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == sticker.png)
    }

    @Test func eachWriteMakesItsOwnFileSoARegeneratedPreviewNeverReusesTheLastOne() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try PreviewFile.write(makeProcessedSticker(), in: directory)
        let second = try PreviewFile.write(makeProcessedSticker(), in: directory)
        #expect(first != second)

        PreviewFile.remove(first)
        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func removingAFileThatIsAlreadyGoneIsFine() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try PreviewFile.write(makeProcessedSticker(), in: directory)
        PreviewFile.remove(url)
        PreviewFile.remove(url)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func theDefaultDirectoryIsTheTemporaryDirectory() throws {
        let url = try PreviewFile.write(makeProcessedSticker())
        defer { PreviewFile.remove(url) }
        #expect(url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @MainActor
    @Test func theFileLoadsAsAnMSStickerDescribedByThePrompt() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { context in
            UIColor.systemYellow.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        let sticker = ProcessedSticker(
            prompt: "a happy cat",
            modelID: "fake-model",
            quality: "low",
            png: try #require(image.pngData()),
            edge: 300
        )

        let url = try PreviewFile.write(sticker)
        defer { PreviewFile.remove(url) }
        let loaded = try MSSticker(contentsOfFileURL: url, localizedDescription: sticker.accessibilityText)
        #expect(loaded.imageFileURL == url)
        #expect(loaded.localizedDescription == "a happy cat")
    }
}
